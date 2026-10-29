package com.apoorvdarshan.calorietracker.services.ai

import com.apoorvdarshan.calorietracker.data.ExerciseItem
import com.apoorvdarshan.calorietracker.data.ExerciseRecord
import com.apoorvdarshan.calorietracker.models.CoachExerciseProposal
import com.apoorvdarshan.calorietracker.models.CoachProposalCollector
import com.apoorvdarshan.calorietracker.models.PlannedExercise
import com.apoorvdarshan.calorietracker.models.UserExercise
import com.apoorvdarshan.calorietracker.models.WorkoutDayPlan
import com.apoorvdarshan.calorietracker.services.voice.RepoFiles
import com.google.gson.Gson
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.google.gson.reflect.TypeToken
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset

class CoachProposalToolsTest {
    private val clock = Clock.fixed(Instant.parse("2026-10-17T12:00:00Z"), ZoneOffset.UTC)

    @Test
    fun proposalToolsAreOfferedOnlyToCoachChat() {
        val withoutCards = CoachTools(weights = emptyList(), bodyFats = emptyList(), foods = emptyList(), exerciseLibrary = library())
        assertEquals(CoachTools.TOOL_NAMES, withoutCards.availableToolNames)
        assertEquals(
            "Proposals are only available in Coach chat.",
            json(withoutCards.execute("propose_add_exercise_to_day", mapOf("catalog_id" to "Leg_Press")))["error"].asString
        )

        val chat = tools(CoachProposalCollector())
        assertEquals(CoachTools.TOOL_NAMES + CoachTools.PROPOSAL_TOOL_NAMES, chat.availableToolNames)
        // The voice assistant offers TOOL_NAMES, and it has no confirmation card.
        assertFalse(CoachTools.PROPOSAL_TOOL_NAMES.any { it in CoachTools.TOOL_NAMES })
        assertEquals(listOf("name", "primary_muscles"), CoachTools.parameterSchemaFor("propose_custom_exercise")["required"])
        assertEquals(listOf("catalog_id"), CoachTools.parameterSchemaFor("propose_add_exercise_to_day")["required"])
        CoachTools.PROPOSAL_TOOL_NAMES.forEach {
            assertTrue(CoachTools.TOOL_DESCRIPTIONS.getValue(it).contains("does NOT save anything"))
        }
    }

    @Test
    fun customExerciseProposalUsesTheLibraryVocabulary() {
        val collector = CoachProposalCollector()
        val tools = tools(collector)
        val result = json(
            tools.execute(
                "propose_custom_exercise",
                mapOf(
                    "name" to "  Iso-Lateral Row  ",
                    "equipment" to "Machine",
                    "primary_muscles" to listOf("middle back", "LATS", "lats"),
                    "secondary_muscles" to listOf("biceps", "lats"),
                    "instructions" to "Sit tall.\n\n Pull both handles. "
                )
            )
        )
        assertEquals("pending_user_confirmation", result["status"].asString)
        assertFalse(result["saved"].asBoolean)
        assertTrue(result["note"].asString.contains("Nothing was saved"))
        val proposal = collector.proposals.single()
        assertEquals(proposal.id, result["proposal_id"].asString)
        assertEquals(CoachExerciseProposal.Kind.CUSTOM_EXERCISE, proposal.kind)
        assertEquals(CoachExerciseProposal.Status.PENDING, proposal.status)
        assertEquals("Iso-Lateral Row", proposal.name)
        assertEquals("Strength", proposal.category)
        assertEquals("Machine", proposal.equipment)
        assertEquals(listOf("Middle Back", "Lats"), proposal.primaryMuscles)
        assertEquals(listOf("Biceps"), proposal.secondaryMuscles)
        assertEquals(listOf("Sit tall.", "Pull both handles."), proposal.instructions)
        assertTrue(UserExercise.isUserExercise(proposal.itemId))

        val commaSeparated = json(
            tools.execute(
                "propose_custom_exercise",
                mapOf(
                    "name" to "Belt Squat", "category" to "olympic weightlifting", "equipment" to "e-z curl bar",
                    "primary_muscles" to "quadriceps, glutes"
                )
            )
        )
        assertFalse(commaSeparated.has("error"))
        val belt = collector.proposals.last()
        assertEquals("Olympic Weightlifting", belt.category)
        assertEquals("E-Z Curl Bar", belt.equipment)
        assertEquals(listOf("Quadriceps", "Glutes"), belt.primaryMuscles)
    }

    @Test
    fun invalidCustomExerciseProposalsAreRejectedWithoutACard() {
        val collector = CoachProposalCollector()
        val tools = tools(collector)
        fun error(args: Map<String, Any?>): String? =
            json(tools.execute("propose_custom_exercise", args)).get("error")?.asString

        assertEquals("name is required.", error(mapOf("primary_muscles" to listOf("chest"))))
        assertEquals("name must be at most 80 characters.", error(mapOf("name" to "x".repeat(81), "primary_muscles" to listOf("chest"))))
        assertTrue(error(mapOf("name" to "Cable Fly", "primary_muscles" to emptyList<String>()))!!.startsWith("primary_muscles needs at least one of:"))
        assertTrue(error(mapOf("name" to "Cable Fly", "primary_muscles" to listOf("pecs")))!!.startsWith("Unknown muscle \"pecs\" in primary_muscles."))
        assertTrue(error(mapOf("name" to "Cable Fly", "primary_muscles" to listOf("chest"), "equipment" to "smith machine"))!!.startsWith("equipment must be one of:"))
        assertTrue(error(mapOf("name" to "Cable Fly", "primary_muscles" to listOf("chest"), "category" to "bodybuilding"))!!.startsWith("category must be one of:"))
        // An exercise the library already has is added, not duplicated.
        assertTrue(error(mapOf("name" to "leg press", "primary_muscles" to listOf("quadriceps")))!!.contains("catalog_id Leg_Press"))
        assertTrue(collector.proposals.isEmpty())
    }

    @Test
    fun addToDayProposalChecksTheExerciseDateAndAmounts() {
        val collector = CoachProposalCollector()
        val tools = tools(collector)
        fun error(args: Map<String, Any?>): String? =
            json(tools.execute("propose_add_exercise_to_day", args)).get("error")?.asString

        assertEquals("catalog_id is required.", error(emptyMap()))
        assertTrue(error(mapOf("catalog_id" to "Zercher_Squat"))!!.startsWith("Unknown catalog_id \"Zercher_Squat\"."))
        assertEquals("date must be an ISO date yyyy-MM-dd.", error(mapOf("catalog_id" to "Leg_Press", "date" to "next week")))
        assertEquals("date must be within one year of today.", error(mapOf("catalog_id" to "Leg_Press", "date" to "2027-11-21")))
        assertEquals("sets must be a whole number from 1 to 12.", error(mapOf("catalog_id" to "Leg_Press", "sets" to 0)))
        assertEquals("sets must be a whole number from 1 to 12.", error(mapOf("catalog_id" to "Leg_Press", "sets" to 13)))
        assertEquals("reps must be a whole number from 1 to 999.", error(mapOf("catalog_id" to "Leg_Press", "reps" to 2.5)))
        assertEquals("reps must be a whole number from 1 to 999.", error(mapOf("catalog_id" to "Leg_Press", "reps" to true)))
        assertTrue(error(mapOf("catalog_id" to "Leg_Press", "date" to "2026-10-18", "reps" to 10))!!.startsWith("reps and duration_minutes record performed work"))
        assertEquals(
            "Running, Treadmill is cardio: use duration_minutes instead of sets or reps.",
            error(mapOf("catalog_id" to "Running_Treadmill", "sets" to 3))
        )
        assertTrue(collector.proposals.isEmpty())

        val today = json(tools.execute("propose_add_exercise_to_day", mapOf("catalog_id" to "Leg_Press", "sets" to "3", "reps" to 10.0)))
        val details = today.getAsJsonObject("proposal")
        assertEquals("2026-10-17", details["date"].asString)
        assertEquals(3, details["sets"].asInt)
        assertEquals(10, details["reps"].asInt)
        assertTrue(details["already_in_diary_that_day"].asBoolean)

        assertFalse(json(tools.execute("propose_add_exercise_to_day", mapOf("catalog_id" to "user_exercise_hammer", "date" to "2026-10-20", "sets" to 4))).has("error"))
        assertFalse(json(tools.execute("propose_add_exercise_to_day", mapOf("catalog_id" to "Running_Treadmill", "date" to "2026-10-15", "duration_minutes" to 25))).has("error"))
        assertEquals(listOf("Leg Press", "Hammer Strength Chest Press", "Running, Treadmill"), collector.proposals.map { it.name })
        assertTrue(collector.proposals.all { it.entryId != null && it.status == CoachExerciseProposal.Status.PENDING })
    }

    @Test
    fun repeatedProposalsShareOneCardAndAReplyIsCapped() {
        val collector = CoachProposalCollector()
        val tools = tools(collector)
        val args = mapOf("catalog_id" to "Leg_Press", "sets" to 3)
        val first = json(tools.execute("propose_add_exercise_to_day", args))
        val again = json(tools.execute("propose_add_exercise_to_day", args))
        assertEquals(first["proposal_id"].asString, again["proposal_id"].asString)
        assertEquals(1, collector.proposals.size)

        for (sets in 1..CoachProposalCollector.MAX_PROPOSALS) {
            tools.execute("propose_add_exercise_to_day", mapOf("catalog_id" to "Leg_Press", "sets" to sets, "reps" to 5))
        }
        assertEquals(CoachProposalCollector.MAX_PROPOSALS, collector.proposals.size)
        val overflow = json(tools.execute("propose_custom_exercise", mapOf("name" to "Cable Fly", "primary_muscles" to listOf("chest"))))
        assertTrue(overflow["error"].asString.contains("already has 10 proposals"))

        collector.reset()
        assertTrue(collector.proposals.isEmpty())
    }

    @Test
    fun proposalVocabularyMatchesTheBundledCatalog() {
        val file = RepoFiles.find("../../ios/calorietracker/Resources/FreeExerciseDB/dist/exercises.json")
        val records: List<ExerciseRecord> = Gson().fromJson(file.readText(), object : TypeToken<List<ExerciseRecord>>() {}.type)
        val catalog = records.mapNotNull { ExerciseItem.from(it) }
        assertEquals(catalog.map { it.category.lowercase() }.toSet(), CoachTools.LIBRARY_CATEGORIES.toSet())

        // Proposed values use the library's own title case, so the exercise editor's pickers match them.
        val collector = CoachProposalCollector()
        tools(collector).execute(
            "propose_custom_exercise",
            mapOf(
                "name" to "Coach Vocabulary Check", "category" to "olympic weightlifting", "equipment" to "e-z curl bar",
                "primary_muscles" to CoachTools.LIBRARY_MUSCLES
            )
        )
        val proposal = collector.proposals.single()
        assertEquals(catalog.flatMap { it.primaryMuscles + it.secondaryMuscles }.toSet(), proposal.primaryMuscles.toSet())
        assertTrue(catalog.any { it.category == proposal.category })
        assertTrue(catalog.any { it.equipment == proposal.equipment })
    }

    private fun tools(collector: CoachProposalCollector) = CoachTools(
        weights = emptyList(),
        bodyFats = emptyList(),
        foods = emptyList(),
        workoutPlans = listOf(WorkoutDayPlan("2026-10-17", listOf(PlannedExercise.from(library()[0])))),
        exerciseLibrary = library(),
        proposals = collector,
        clock = clock
    )

    private fun library(): List<ExerciseItem> = listOf(
        item("Leg_Press", "Leg Press", "Strength", listOf("Quadriceps")),
        item("Running_Treadmill", "Running, Treadmill", "Cardio", listOf("Quadriceps")),
        item("user_exercise_hammer", "Hammer Strength Chest Press", "Strength", listOf("Chest"))
    )

    private fun item(id: String, name: String, category: String, muscles: List<String>) = ExerciseItem(
        id = id,
        name = name,
        level = "Beginner",
        imagePaths = emptyList(),
        force = "Unspecified",
        mechanic = "Unspecified",
        category = category,
        equipment = "Machine",
        primaryMuscles = muscles,
        secondaryMuscles = emptyList(),
        instructions = emptyList()
    )

    private fun json(value: String): JsonObject = JsonParser.parseString(value).asJsonObject
}
