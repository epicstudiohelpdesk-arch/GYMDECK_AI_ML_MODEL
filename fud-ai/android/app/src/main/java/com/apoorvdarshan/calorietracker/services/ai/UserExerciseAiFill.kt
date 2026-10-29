package com.apoorvdarshan.calorietracker.services.ai

import com.apoorvdarshan.calorietracker.models.UserExerciseDraft
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import java.text.Normalizer
import java.util.Locale

/**
 * "Fill with AI" in the custom exercise editor (#499), mirroring iOS `UserExerciseAIFill`.
 * The prompt lists the catalog's own metadata values and the parser keeps only values from
 * those lists, so every prefilled field matches an editor option. Nothing is saved here: the
 * suggestion prefills the draft and the user reviews it.
 */
object UserExerciseAiFill {
    data class Options(
        val categories: List<String>,
        val equipment: List<String>,
        val primaryMuscles: List<String>,
        val secondaryMuscles: List<String>
    )

    data class Suggestion(
        val name: String,
        val category: String? = null,
        val equipment: String? = null,
        val primaryMuscles: List<String> = emptyList(),
        val secondaryMuscles: List<String> = emptyList(),
        val instructions: List<String> = emptyList()
    )

    const val MAX_NAME_LENGTH = 80
    const val MAX_PRIMARY_MUSCLES = 3
    const val MAX_SECONDARY_MUSCLES = 4
    const val MAX_INSTRUCTION_STEPS = 8
    const val MAX_INSTRUCTION_LENGTH = 300

    private val listMarker = Regex("""^(?:\d{1,2}[.)]|[-*•])\s+""")
    private val whitespace = Regex("""\s+""")
    private val combiningMarks = Regex("""\p{Mn}+""")

    fun prompt(options: Options): String = """
        Identify the exercise in this photo. It may show a gym machine, a piece of exercise equipment, or a person doing the exercise. Your answer prefills a custom exercise form that the user reviews before saving.
        Respond ONLY with a JSON object in this exact format, no other text:
        {"name":"...","category":"...","equipment":"...","primary_muscles":["..."],"secondary_muscles":["..."],"instructions":["..."]}
        - name: the common name of the exercise, at most 60 characters.
        - category: exactly one value from the allowed categories.
        - equipment: exactly one value from the allowed equipment, or null when none fits.
        - primary_muscles: 1 to 3 main muscles worked, each from the allowed primary muscles.
        - secondary_muscles: up to 4 other muscles worked, each from the allowed secondary muscles. Never repeat a primary muscle.
        - instructions: 2 to 6 short steps for doing the exercise with good form, one step per item, without numbering.
        Copy every category, equipment and muscle value exactly as written in the lists below. Never use a value that is not listed.
        If the photo shows no exercise, exercise equipment or person exercising, return {"name":null}.
        Allowed categories: ${jsonList(options.categories)}
        Allowed equipment: ${jsonList(options.equipment)}
        Allowed primary muscles: ${jsonList(options.primaryMuscles)}
        Allowed secondary muscles: ${jsonList(options.secondaryMuscles)}
    """.trimIndent()

    /**
     * Reads the AI reply. A missing name means the reply is unusable ([AiError.InvalidResponse]);
     * any category, equipment or muscle outside [options] is dropped.
     */
    fun parse(response: String, options: Options): Suggestion {
        val json = runCatching { Json.parseToJsonElement(FoodJsonParser.extractJson(response)) as? JsonObject }
            .getOrNull() ?: throw AiError.InvalidResponse
        val name = json.string("name")?.let(::collapseWhitespace)?.take(MAX_NAME_LENGTH)?.trim()
        if (name.isNullOrEmpty()) throw AiError.InvalidResponse

        val primaryMuscles = matches(json["primary_muscles"], options.primaryMuscles).take(MAX_PRIMARY_MUSCLES)
        val secondaryMuscles = matches(json["secondary_muscles"], options.secondaryMuscles)
            .filter { it !in primaryMuscles }
            .take(MAX_SECONDARY_MUSCLES)

        return Suggestion(
            name = name,
            category = match(json.string("category"), options.categories),
            equipment = match(json.string("equipment"), options.equipment),
            primaryMuscles = primaryMuscles,
            secondaryMuscles = secondaryMuscles,
            instructions = instructionSteps(json["instructions"])
        )
    }

    /**
     * Prefills the editor from a suggestion. Fields the AI left out or answered with an unlisted
     * value keep their current values; the photo is untouched.
     */
    fun apply(suggestion: Suggestion, draft: UserExerciseDraft): UserExerciseDraft {
        var result = draft.copy(
            name = suggestion.name,
            category = suggestion.category ?: draft.category,
            equipment = suggestion.equipment ?: draft.equipment
        )
        if (suggestion.primaryMuscles.isNotEmpty()) {
            result = result.copy(primaryMuscles = suggestion.primaryMuscles)
        }
        val suggestedSecondary = suggestion.secondaryMuscles.filter { it !in result.primaryMuscles }
        if (suggestedSecondary.isNotEmpty()) {
            result = result.copy(secondaryMuscles = suggestedSecondary)
        } else if (suggestion.primaryMuscles.isNotEmpty()) {
            // No usable secondary muscles: keep the current ones, minus any that are now primary.
            result = result.copy(secondaryMuscles = result.secondaryMuscles.filter { it !in result.primaryMuscles })
        }
        if (suggestion.instructions.isNotEmpty()) {
            result = result.copy(instructions = suggestion.instructions.joinToString("\n"))
        }
        return result
    }

    /** The allowed value that [raw] names, ignoring case, accents and spacing. */
    fun match(raw: String?, allowed: List<String>): String? {
        val key = raw?.let(::matchKey)?.takeIf { it.isNotEmpty() } ?: return null
        return allowed.firstOrNull { matchKey(it) == key }
    }

    private fun matches(raw: JsonElement?, allowed: List<String>): List<String> {
        val values = when (raw) {
            is JsonArray -> raw.mapNotNull { (it as? JsonPrimitive)?.takeIf(JsonPrimitive::isString)?.content }
            is JsonPrimitive -> listOfNotNull(raw.takeIf(JsonPrimitive::isString)?.content)
            else -> emptyList()
        }
        return values.mapNotNull { match(it, allowed) }.distinct()
    }

    private fun instructionSteps(raw: JsonElement?): List<String> {
        val texts = when (raw) {
            is JsonArray -> raw.mapNotNull { (it as? JsonPrimitive)?.takeIf(JsonPrimitive::isString)?.content }
            is JsonPrimitive -> listOfNotNull(raw.takeIf(JsonPrimitive::isString)?.content)
            else -> emptyList()
        }
        return texts.asSequence()
            .flatMap { it.lines() }
            .map(::stepText)
            .filter { it.isNotEmpty() }
            .take(MAX_INSTRUCTION_STEPS)
            .map { it.take(MAX_INSTRUCTION_LENGTH) }
            .toList()
    }

    /** Trims a step and drops a leading list marker such as "1.", "2)" or "-". */
    private fun stepText(line: String): String = collapseWhitespace(line).replaceFirst(listMarker, "").trim()

    private fun matchKey(value: String): String =
        Normalizer.normalize(collapseWhitespace(value), Normalizer.Form.NFD)
            .replace(combiningMarks, "")
            .lowercase(Locale.ROOT)

    private fun collapseWhitespace(value: String): String = value.trim().replace(whitespace, " ")

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf(JsonPrimitive::isString)?.content

    private fun jsonList(values: List<String>): String =
        buildJsonArray { values.forEach { add(JsonPrimitive(it)) } }.toString()
}
