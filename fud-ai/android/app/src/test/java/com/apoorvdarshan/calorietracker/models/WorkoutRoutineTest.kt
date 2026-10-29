package com.apoorvdarshan.calorietracker.models

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class WorkoutRoutineTest {
    private fun exercise(
        itemId: String,
        sets: List<PlannedSet> = listOf(PlannedSet()),
        category: String = "strength",
        timer: ExerciseTimer? = null
    ) = PlannedExercise(
        itemId = itemId,
        name = itemId.replaceFirstChar(Char::uppercase),
        level = "intermediate",
        imagePaths = emptyList(),
        force = "push",
        mechanic = "compound",
        category = category,
        equipment = "barbell",
        primaryMuscles = listOf("chest"),
        secondaryMuscles = emptyList(),
        instructions = emptyList(),
        sets = sets,
        timer = timer
    )

    private fun logged(weight: String, reps: String, rpe: String = "") = PlannedSet(
        weight = weight,
        weightUnit = WorkoutWeightUnit.KG,
        reps = reps,
        rpe = rpe,
        rpeScale = if (rpe.isEmpty()) null else WorkoutRpeScale.STRENGTH
    )

    @Test
    fun namesAreTrimmedCollapsedAndCapped() {
        assertEquals("Push day", WorkoutRoutinePlanner.sanitizedName("  Push \n  day  "))
        assertEquals("", WorkoutRoutinePlanner.sanitizedName("   "))
        assertEquals(WorkoutRoutinePlanner.MAX_NAME_LENGTH, WorkoutRoutinePlanner.sanitizedName("x".repeat(90)).length)
    }

    @Test
    fun templateKeepsPlannedLoadsAndRepsButNotRpeTimersOrIdentities() {
        val bench = exercise(
            "bench",
            sets = listOf(logged("60", "10", rpe = "8"), logged("62.5", "8", rpe = "9")),
            timer = ExerciseTimer(accumulatedSeconds = 30.0, savedDurationSeconds = 30.0)
        )
        val run = exercise("run", sets = listOf(PlannedSet(reps = "5")), category = "cardio",
            timer = ExerciseTimer(accumulatedSeconds = 600.0, savedDurationSeconds = 600.0))

        val template = WorkoutRoutinePlanner.template(listOf(bench, run))

        assertEquals(listOf("bench", "run"), template.map { it.itemId })
        val benchPlan = template[0]
        assertNotEquals(bench.id, benchPlan.id)
        assertNull(benchPlan.timer)
        assertEquals(listOf("60", "62.5"), benchPlan.sets.map { it.weight })
        assertEquals(listOf("10", "8"), benchPlan.sets.map { it.reps })
        assertEquals(listOf(WorkoutWeightUnit.KG, WorkoutWeightUnit.KG), benchPlan.sets.map { it.weightUnit })
        assertTrue(benchPlan.sets.all { it.rpe.isEmpty() && it.rpeScale == null })
        assertTrue(benchPlan.sets.map { it.id }.intersect(bench.sets.map { it.id }.toSet()).isEmpty())
        // Cardio keeps only the shape of a newly picked exercise: no time, no hidden set values.
        assertNull(template[1].timer)
        assertEquals(listOf(PlannedSet().copy(id = template[1].sets.single().id)), template[1].sets)
    }

    @Test
    fun applyingToAnEmptyDayAddsFreshCopiesOfEveryRoutineExercise() {
        val routine = WorkoutRoutinePlanner.template(
            listOf(exercise("bench", sets = listOf(logged("60", "10"), logged("60", "10"))), exercise("row"))
        )

        val day = WorkoutRoutinePlanner.merged(emptyList(), routine)
        val again = WorkoutRoutinePlanner.merged(emptyList(), routine)

        assertEquals(listOf("bench", "row"), day.map { it.itemId })
        assertEquals(listOf("10", "10"), day[0].sets.map { it.reps })
        // Each application is its own diary entry with its own identities.
        assertNotEquals(day.map { it.id }, again.map { it.id })
        assertNotEquals(routine.map { it.id }, day.map { it.id })
        assertTrue(day.flatMap { it.sets }.map { it.id }.intersect(routine.flatMap { it.sets }.map { it.id }.toSet()).isEmpty())
    }

    @Test
    fun applyingToADayNeverOverwritesLoggedSetsAndAppendsTheRest() {
        val loggedBench = exercise("bench", sets = listOf(logged("70", "5", rpe = "9")))
        val blankSquat = exercise("squat")
        val timedPlank = exercise("plank", sets = listOf(PlannedSet()),
            timer = ExerciseTimer(runningSince = Instant.parse("2026-10-18T10:00:00Z")))
        val routine = WorkoutRoutinePlanner.template(listOf(
            exercise("bench", sets = listOf(logged("60", "10"), logged("60", "10"), logged("60", "10"))),
            exercise("squat", sets = listOf(logged("100", "5"), logged("100", "5"))),
            exercise("plank", sets = listOf(logged("", "60"))),
            exercise("row", sets = listOf(logged("50", "12")))
        ))

        val merged = WorkoutRoutinePlanner.merged(listOf(loggedBench, blankSquat, timedPlank), routine)

        assertEquals(listOf("bench", "squat", "plank", "row"), merged.map { it.itemId })
        // Logged work stays exactly as it was.
        assertEquals(loggedBench, merged[0])
        assertEquals(timedPlank, merged[2])
        // A matching entry with nothing logged takes the planned sets, keeping its identity.
        assertEquals(blankSquat.id, merged[1].id)
        assertEquals(listOf("100", "100"), merged[1].sets.map { it.weight })
        assertEquals(listOf("5", "5"), merged[1].sets.map { it.reps })
        assertEquals(listOf("12"), merged[3].sets.map { it.reps })
    }

    @Test
    fun repeatedExercisesInARoutineMatchDayEntriesInOrder() {
        val day = listOf(exercise("bench", sets = listOf(logged("80", "3"))))
        val routine = WorkoutRoutinePlanner.template(listOf(
            exercise("bench", sets = listOf(logged("80", "3"))),
            exercise("bench", sets = listOf(logged("60", "12"), logged("60", "12")))
        ))

        val merged = WorkoutRoutinePlanner.merged(day, routine)

        // The first bench meets the logged entry and leaves it alone; the back-off bench is added.
        assertEquals(2, merged.size)
        assertEquals(day[0], merged[0])
        assertEquals(listOf("12", "12"), merged[1].sets.map { it.reps })
    }

    @Test
    fun onlyEntriesWithoutLoggedValuesCanReceiveAPlan() {
        assertTrue(WorkoutRoutinePlanner.canReceivePlan(exercise("bench")))
        assertTrue(WorkoutRoutinePlanner.canReceivePlan(exercise("bench", timer = ExerciseTimer(intensity = WorkoutIntensity.VIGOROUS))))
        assertFalse(WorkoutRoutinePlanner.canReceivePlan(exercise("bench", sets = listOf(PlannedSet(weight = "40")))))
        assertFalse(WorkoutRoutinePlanner.canReceivePlan(exercise("bench", sets = listOf(PlannedSet(rpe = "7")))))
        assertFalse(WorkoutRoutinePlanner.canReceivePlan(exercise("bench", timer = ExerciseTimer(accumulatedSeconds = 12.0))))
    }
}
