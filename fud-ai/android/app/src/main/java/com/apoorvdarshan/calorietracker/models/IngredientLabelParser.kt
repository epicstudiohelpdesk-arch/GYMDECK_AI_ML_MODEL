package com.apoorvdarshan.calorietracker.models

import java.text.Normalizer

/** One entry of a scanned ingredient label, for display only (#428). */
data class IngredientLabelItem(
    val segments: List<Segment>,
    /** True when the entry mentions one of the user's allergen sensitivities. */
    val matchesSensitivity: Boolean = false
) {
    data class Segment(
        val text: String,
        /** Open Food Facts marks declared allergens with underscores, e.g. `_milk_`. */
        val isAllergen: Boolean
    )

    val text: String get() = segments.joinToString("") { it.text }

    /**
     * Whether screen readers announce the entry as a possible allergen: it matches a sensitivity,
     * or Open Food Facts flags part of it (shown in bold, which TalkBack does not read).
     */
    val announcesAllergen: Boolean get() = matchesSensitivity || segments.any { it.isAllergen }
}

/** A scanned ingredient label split for display (#428). */
data class IngredientLabel(
    /** One entry per ingredient. Empty when the label does not make a useful list. */
    val items: List<IngredientLabelItem>,
    /**
     * Sentences after the ingredient list, such as "May contain traces of nuts.", kept whole so
     * precautionary statements never read as ingredients.
     */
    val notes: List<IngredientLabelItem> = emptyList(),
    /**
     * The whole label as one entry when it does not make a useful list, so a single-ingredient
     * label or one longer than [IngredientLabelParser.MAX_ITEMS] keeps its sensitivity warning.
     * Null for a list or a blank label.
     */
    val paragraph: IngredientLabelItem? = null
)

/**
 * Turns an Open Food Facts ingredient label into a readable list (#428). Display only: the
 * stored label and the allergen check keep using the whole text, and label entries never become
 * macro-bearing meal ingredients. Mirrors iOS IngredientLabelParser; keep both in sync.
 */
object IngredientLabelParser {
    /** Longer labels stay a paragraph so nothing is cut off. */
    const val MAX_ITEMS = 60

    private val separators = setOf(',', ';', '，', '；', '、', '\u060C', '\u061B')
    private val openers = setOf('(', '[', '{', '（', '［', '【')
    private val closers = setOf(')', ']', '}', '）', '］', '】')
    private val headingStems = listOf(
        "ingred", "zutaten", "składnik", "skladnik", "slozeni", "icindekiler", "tərkib", "terkib",
        "состав", "склад", "配料", "原材料", "원재료", "المكونات", "सामग्री"
    )
    // Includes no-break spaces, which the JVM's \s leaves out but iOS (ICU) collapses.
    private val whitespace = "[\\s\\u00A0\\u2007\\u202F]+".toRegex()
    private val combiningMarks = "\\p{Mn}+".toRegex()

    /**
     * Precautionary statements that end the list after a full stop even in lower case
     * ("salt. may contain nuts"), compared without case or accents.
     */
    private val statementStarts = listOf(
        "may contain", "contains", "traces", "allergy advice", "allergen advice",
        "peut contenir", "contient", "kann spuren", "kann enthalten", "enthält",
        "puede contener", "contiene", "può contenere", "kan sporen", "kan bevatten", "bevat",
        "może zawierać", "zawiera", "pode conter", "contém", "poate conține", "conține",
        "может содержать", "содержит", "може містити", "містить", "může obsahovat", "obsahuje",
        "eser miktarda", "قد يحتوي", "يحتوي"
    ).map(::fold)
    private val allergenSpan = Regex(
        "<span\\s+class\\s*=\\s*[\"']allergen[\"']\\s*>(.*?)</span\\s*>",
        setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)
    )
    // The characters Swift's Character.isNewline accepts, so both platforms end sentences alike.
    private val lineBreaks = setOf('\n', '\u000B', '\u000C', '\r', '\u0085', '\u2028', '\u2029')
    private val markerEdgePunctuation =
        setOf(':', ';', ',', '.', '：', '；', '，', '、', '。', '\u060C', '\u061B')
    private val spanTag = Regex("</?span\\b[^>]*>", RegexOption.IGNORE_CASE)
    private val htmlEntity = Regex("&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|amp|lt|gt|quot|apos|nbsp);")
    private val namedEntities = mapOf(
        "amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'", "nbsp" to "\u00A0"
    )

    /**
     * The label's first sentence split into entries, plus any later sentences as notes. The
     * entries are empty when that sentence does not make a useful list (a single entry, or more
     * than [MAX_ITEMS]); show [IngredientLabel.paragraph] instead.
     */
    fun parse(text: String, sensitivities: List<String> = emptyList()): IngredientLabel {
        val sentences = splitSentences(stripHeading(text))
        val parts = splitTopLevel(sentences.firstOrNull().orEmpty())
        if (parts.size <= 1 || parts.size > MAX_ITEMS) {
            val whole = text.trim()
            return IngredientLabel(
                items = emptyList(),
                paragraph = whole.takeIf { it.isNotEmpty() }?.let { item(it, sensitivities) }
            )
        }
        return IngredientLabel(
            items = parts.map { item(it, sensitivities) },
            notes = sentences.drop(1)
                .map { it.replace(whitespace, " ").trim() }
                .filter { it.isNotEmpty() }
                .map { item(it, sensitivities) }
        )
    }

    /** The entries of [parse]. */
    fun items(text: String, sensitivities: List<String> = emptyList()): List<IngredientLabelItem> =
        parse(text, sensitivities).items

    private fun item(text: String, sensitivities: List<String>): IngredientLabelItem {
        val segments = segments(text)
        return IngredientLabelItem(
            segments = segments,
            matchesSensitivity = AllergenAnalysis.mentionsAny(
                sensitivities,
                segments.joinToString("") { it.text }
            )
        )
    }

    /**
     * Open Food Facts' `ingredients_text` often carries no allergen markers; the allergens it
     * flags are in `ingredients_text_with_allergens` as `<span class="allergen">` tags. Returns
     * [plain] with those spans turned into the `_allergen_` markers [segments] reads, or [plain]
     * itself when the markup is missing or does not match it word for word.
     */
    fun markingAllergens(plain: String?, markup: String?): String? {
        val fallback = plain?.trim()?.takeIf { it.isNotEmpty() }
        if (markup.isNullOrBlank()) return fallback
        val marked = decodeEntities(
            markup.replace(allergenSpan) { match ->
                val inner = match.groupValues[1].replace(spanTag, "").replace("_", "")
                // Spaces and punctuation at the edges stay outside the marker ("contenir: _cacahuète_").
                val leading = inner.takeWhile(::isMarkerEdge)
                val trailing = inner.drop(leading.length).takeLastWhile(::isMarkerEdge)
                val core = inner.substring(leading.length, inner.length - trailing.length)
                if (core.isEmpty()) inner else leading + "_" + core + "_" + trailing
            }.replace(spanTag, "")
        ).trim()
        if (marked.isEmpty()) return fallback
        if (fallback != null && comparable(marked) != comparable(fallback)) return fallback
        return marked
    }

    /** Splits `_allergen_` markers into emphasized segments and drops stray underscores. */
    fun segments(text: String): List<IngredientLabelItem.Segment> {
        val result = mutableListOf<IngredientLabelItem.Segment>()
        val plain = StringBuilder()
        var index = 0
        while (index < text.length) {
            val open = text.indexOf('_', index)
            if (open < 0) break
            val close = text.indexOf('_', open + 1)
            if (close < 0) break
            plain.append(text, index, open)
            val marked = text.substring(open + 1, close)
            if (marked.isBlank()) {
                plain.append(marked)
            } else {
                if (plain.isNotEmpty()) {
                    result += IngredientLabelItem.Segment(plain.toString(), isAllergen = false)
                    plain.clear()
                }
                result += IngredientLabelItem.Segment(marked, isAllergen = true)
            }
            index = close + 1
        }
        plain.append(text.substring(index).replace("_", ""))
        if (plain.isNotEmpty()) result += IngredientLabelItem.Segment(plain.toString(), isAllergen = false)
        return result
    }

    /** Removes a leading "Ingredients:" style heading in the app's label languages. */
    fun stripHeading(text: String): String {
        val trimmed = text.trim()
        val colon = trimmed.indexOfFirst { it == ':' || it == '：' }
        if (colon < 0) return trimmed
        val heading = trimmed.substring(0, colon).trim()
        if (heading.isEmpty() ||
            heading.codePointCount(0, heading.length) > 30 ||
            heading.any { it in separators || it in openers }
        ) {
            return trimmed
        }
        val lowered = heading.lowercase()
        val folded = Normalizer.normalize(lowered, Normalizer.Form.NFD).replace(combiningMarks, "")
        if (headingStems.none { lowered.contains(it) || folded.contains(it) }) return trimmed
        return trimmed.substring(colon + 1).trim()
    }

    /**
     * Splits at full stops outside brackets that end a sentence: followed by a line break, by
     * a capitalised word ("… acerola. May contain …"), or by a precautionary statement in any
     * case ("… salt. may contain …"). Decimals ("8.7%") and abbreviations before a single letter
     * ("vit. C") stay together. Each sentence keeps its full stop.
     */
    fun splitSentences(text: String): List<String> {
        val sentences = mutableListOf<String>()
        var start = 0
        var depth = 0
        text.forEachIndexed { index, char ->
            when {
                char in openers -> depth += 1
                char in closers -> depth = maxOf(0, depth - 1)
                depth == 0 && char == '.' && endsSentence(text, index) -> {
                    sentences += text.substring(start, index + 1)
                    start = index + 1
                }
            }
        }
        sentences += text.substring(start)
        return sentences.map { it.trim() }.filter { it.isNotEmpty() }
    }

    /** Splits on commas and semicolons outside brackets, keeping decimal commas ("8,7%"). */
    fun splitTopLevel(text: String): List<String> {
        val parts = mutableListOf<String>()
        val current = StringBuilder()
        var depth = 0
        text.forEachIndexed { index, char ->
            when {
                char in openers -> depth += 1
                char in closers -> depth = maxOf(0, depth - 1)
                depth == 0 && char in separators && !isDecimalComma(text, index) -> {
                    parts += current.toString()
                    current.clear()
                    return@forEachIndexed
                }
            }
            current.append(char)
        }
        parts += current.toString()
        return parts.map(::clean).filter { it.isNotEmpty() }
    }

    private fun endsSentence(text: String, index: Int): Boolean {
        var next = index + 1
        if (next >= text.length || !text[next].isWhitespace()) return false
        var lineBreak = false
        while (next < text.length && text[next].isWhitespace()) {
            if (text[next] in lineBreaks) lineBreak = true
            next += 1
        }
        if (next >= text.length) return false
        return lineBreak ||
            (text[next].isUpperCase() && next + 1 < text.length && text[next + 1].isLetter()) ||
            startsStatement(text, next)
    }

    private fun startsStatement(text: String, index: Int): Boolean {
        val folded = fold(text.substring(index, minOf(text.length, index + 48)))
        return statementStarts.any { phrase ->
            folded.startsWith(phrase) && (folded.length == phrase.length || !folded[phrase.length].isLetter())
        }
    }

    /** Lower case without accents, matching iOS's case- and diacritic-insensitive folding. */
    private fun fold(text: String): String =
        Normalizer.normalize(text, Normalizer.Form.NFD).replace(combiningMarks, "").lowercase()

    private fun isMarkerEdge(char: Char): Boolean = char.isWhitespace() || char in markerEdgePunctuation

    private fun decodeEntities(text: String): String = htmlEntity.replace(text) { match ->
        val name = match.groupValues[1]
        val codePoint = when {
            name.startsWith("#x") || name.startsWith("#X") -> name.drop(2).toIntOrNull(16)
            name.startsWith("#") -> name.drop(1).toIntOrNull()
            else -> null
        }
        when {
            codePoint != null && Character.isValidCodePoint(codePoint) -> String(Character.toChars(codePoint))
            codePoint != null -> match.value
            else -> namedEntities[name] ?: match.value
        }
    }

    /** Entities decoded on both sides, so a plain label that still has `&amp;` can match. */
    private fun comparable(text: String): String =
        decodeEntities(text).replace("_", "").replace(whitespace, " ").trim()

    private fun isDecimalComma(text: String, index: Int): Boolean =
        text[index] == ',' && index > 0 && index + 1 < text.length &&
            text[index - 1] in '0'..'9' && text[index + 1] in '0'..'9'

    private fun clean(part: String): String =
        part.replace(whitespace, " ").trim().trimEnd('.', '。', ' ')
}
