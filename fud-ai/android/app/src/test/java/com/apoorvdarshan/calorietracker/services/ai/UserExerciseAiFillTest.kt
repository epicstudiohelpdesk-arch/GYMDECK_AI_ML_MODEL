package com.apoorvdarshan.calorietracker.services.ai

import com.apoorvdarshan.calorietracker.models.UserExerciseDraft
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class UserExerciseAiFillTest {
    private val options = UserExerciseAiFill.Options(
        categories = listOf("Strength", "Stretching", "Cardio"),
        equipment = listOf("Barbell", "Body Only", "Cable", "E-Z Curl Bar", "Machine"),
        primaryMuscles = listOf("Chest", "Lats", "Lower Back", "Triceps"),
        secondaryMuscles = listOf("Biceps", "Chest", "Shoulders", "Triceps")
    )

    @Test fun promptListsEveryAllowedValue() {
        val prompt = UserExerciseAiFill.prompt(options)

        assertTrue(prompt.contains("""Allowed categories: ["Strength","Stretching","Cardio"]"""))
        assertTrue(prompt.contains("""Allowed equipment: ["Barbell","Body Only","Cable","E-Z Curl Bar","Machine"]"""))
        assertTrue(prompt.contains("""Allowed primary muscles: ["Chest","Lats","Lower Back","Triceps"]"""))
        assertTrue(prompt.contains("""Allowed secondary muscles: ["Biceps","Chest","Shoulders","Triceps"]"""))
        assertTrue(prompt.contains("\"primary_muscles\""))
        assertTrue(prompt.contains("\"instructions\""))
    }

    @Test fun parsesAValidReply() {
        val reply = """{"name":"Cable Chest Fly","category":"Strength","equipment":"Cable","primary_muscles":["Chest"],"secondary_muscles":["Shoulders","Triceps"],"instructions":["Stand between the pulleys.","Bring the handles together in front of your chest."]}"""

        val suggestion = UserExerciseAiFill.parse(reply, options)

        assertEquals(
            UserExerciseAiFill.Suggestion(
                name = "Cable Chest Fly",
                category = "Strength",
                equipment = "Cable",
                primaryMuscles = listOf("Chest"),
                secondaryMuscles = listOf("Shoulders", "Triceps"),
                instructions = listOf("Stand between the pulleys.", "Bring the handles together in front of your chest.")
            ),
            suggestion
        )
    }

    @Test fun keepsOnlyListedValuesInTheirCatalogSpelling() {
        val reply = """
            Here is the exercise:
            ```json
            {"name":"  Lat   Pulldown ","category":"Calisthenics","equipment":"smith machine","primary_muscles":["lats","Rear Delts","LATS","lower  back"],"secondary_muscles":["biceps","Lats","Forearms","chest"],"instructions":"1. Grip the bar wide.\n2) Pull it to your upper chest.\n\n- Return slowly."}
            ```
        """.trimIndent()

        val suggestion = UserExerciseAiFill.parse(reply, options)

        assertEquals("Lat Pulldown", suggestion.name)
        assertNull(suggestion.category)
        assertNull(suggestion.equipment)
        assertEquals(listOf("Lats", "Lower Back"), suggestion.primaryMuscles)
        // "Lats" is not a secondary option and "Forearms" is not listed at all.
        assertEquals(listOf("Biceps", "Chest"), suggestion.secondaryMuscles)
        assertEquals(
            listOf("Grip the bar wide.", "Pull it to your upper chest.", "Return slowly."),
            suggestion.instructions
        )
    }

    @Test fun secondaryMusclesNeverRepeatPrimaryOnes() {
        val reply = """{"name":"Close-Grip Bench Press","category":"strength","equipment":"barbell","primary_muscles":["Triceps"],"secondary_muscles":["Triceps","Chest"]}"""

        val suggestion = UserExerciseAiFill.parse(reply, options)

        assertEquals("Strength", suggestion.category)
        assertEquals("Barbell", suggestion.equipment)
        assertEquals(listOf("Triceps"), suggestion.primaryMuscles)
        assertEquals(listOf("Chest"), suggestion.secondaryMuscles)
        assertTrue(suggestion.instructions.isEmpty())
    }

    @Test fun capsListsAndLengths() {
        val steps = (1..12).joinToString(",") { "\"Step $it\"" }
        val reply = """{"name":"${"a".repeat(200)}","primary_muscles":["Chest","Lats","Lower Back","Triceps"],"instructions":[$steps]}"""

        val suggestion = UserExerciseAiFill.parse(reply, options)

        assertEquals(UserExerciseAiFill.MAX_NAME_LENGTH, suggestion.name.length)
        assertEquals(listOf("Chest", "Lats", "Lower Back"), suggestion.primaryMuscles)
        assertEquals(UserExerciseAiFill.MAX_INSTRUCTION_STEPS, suggestion.instructions.size)
    }

    @Test fun rejectsUnusableReplies() {
        val replies = listOf(
            "I can't tell what exercise this is.",
            "",
            """{"name":null}""",
            """{"name":"   "}""",
            """{"category":"Strength","equipment":"Cable"}""",
            """{"name":42}""",
            """["Bench Press"]""",
            """{"name":"Bench Press",""",
        )
        for (reply in replies) {
            val error = runCatching { UserExerciseAiFill.parse(reply, options) }.exceptionOrNull()
            assertSame("reply: $reply", AiError.InvalidResponse, error)
        }
    }

    @Test fun applyingASuggestionPrefillsTheDraftWithoutTouchingThePhoto() {
        val photo = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte())
        val draft = UserExerciseDraft(
            name = "My exercise",
            instructions = "Old step",
            level = "Intermediate",
            category = "Cardio",
            equipment = "Machine",
            primaryMuscles = listOf("Lats"),
            secondaryMuscles = listOf("Biceps"),
            photoBytes = photo
        )

        val filled = UserExerciseAiFill.apply(
            UserExerciseAiFill.Suggestion(
                name = "Chest Press",
                category = "Strength",
                equipment = null,
                primaryMuscles = listOf("Chest"),
                secondaryMuscles = emptyList(),
                instructions = listOf("Sit tall.", "Press the handles forward.")
            ),
            draft
        )

        assertEquals("Chest Press", filled.name)
        assertEquals("Strength", filled.category)
        assertEquals("Machine", filled.equipment)
        assertEquals(listOf("Chest"), filled.primaryMuscles)
        assertEquals(listOf("Biceps"), filled.secondaryMuscles)
        assertEquals("Sit tall.\nPress the handles forward.", filled.instructions)
        assertEquals("Intermediate", filled.level)
        assertArrayEquals(photo, filled.photoBytes)
        assertFalse(filled.removePhoto)
    }

    @Test fun emptySuggestionFieldsKeepTheCurrentValues() {
        val draft = UserExerciseDraft(
            name = "Old",
            instructions = "Keep me",
            primaryMuscles = listOf("Lats"),
            secondaryMuscles = listOf("Biceps")
        )

        val filled = UserExerciseAiFill.apply(UserExerciseAiFill.Suggestion(name = "Pull-Up"), draft)

        assertEquals("Pull-Up", filled.name)
        assertEquals("Strength", filled.category)
        assertEquals(listOf("Lats"), filled.primaryMuscles)
        assertEquals(listOf("Biceps"), filled.secondaryMuscles)
        assertEquals("Keep me", filled.instructions)
    }

    @Test fun primaryMusclesWithoutUsableSecondaryMusclesKeepTheCurrentSecondaryMuscles() {
        val draft = UserExerciseDraft(
            name = "Old",
            primaryMuscles = listOf("Lats"),
            secondaryMuscles = listOf("Biceps", "Chest", "Shoulders")
        )

        val filled = UserExerciseAiFill.apply(
            UserExerciseAiFill.Suggestion(name = "Chest Press", primaryMuscles = listOf("Chest")),
            draft
        )

        assertEquals(listOf("Chest"), filled.primaryMuscles)
        // Chest is primary now, so it leaves the secondary list; the rest stay.
        assertEquals(listOf("Biceps", "Shoulders"), filled.secondaryMuscles)

        // Secondary muscles that only repeat a primary muscle are not usable either.
        val refilled = UserExerciseAiFill.apply(
            UserExerciseAiFill.Suggestion(
                name = "Chest Press",
                primaryMuscles = listOf("Triceps"),
                secondaryMuscles = listOf("Triceps")
            ),
            filled
        )

        assertEquals(listOf("Triceps"), refilled.primaryMuscles)
        assertEquals(listOf("Biceps", "Shoulders"), refilled.secondaryMuscles)
    }

    @Test fun suggestedSecondaryMusclesReplaceTheCurrentOnes() {
        val draft = UserExerciseDraft(
            name = "Old",
            primaryMuscles = listOf("Lats"),
            secondaryMuscles = listOf("Biceps")
        )

        val filled = UserExerciseAiFill.apply(
            UserExerciseAiFill.Suggestion(
                name = "Chest Press",
                primaryMuscles = listOf("Chest"),
                secondaryMuscles = listOf("Shoulders", "Triceps")
            ),
            draft
        )

        assertEquals(listOf("Chest"), filled.primaryMuscles)
        assertEquals(listOf("Shoulders", "Triceps"), filled.secondaryMuscles)
    }
}
