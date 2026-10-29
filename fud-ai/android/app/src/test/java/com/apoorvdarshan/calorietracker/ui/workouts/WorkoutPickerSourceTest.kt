package com.apoorvdarshan.calorietracker.ui.workouts

import com.apoorvdarshan.calorietracker.models.UserExercise
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkoutPickerSourceTest {
    private val userExerciseId = UserExercise.newId()
    private val savedIds = setOf("Barbell_Squat")

    @Test
    fun mineIncludesOnlyUserCreatedExercises() {
        assertTrue(WorkoutPickerSource.MINE.includes(userExerciseId, savedIds))
        assertFalse(WorkoutPickerSource.MINE.includes("Barbell_Squat", savedIds))
        assertFalse(WorkoutPickerSource.MINE.includes("custom_activity_walk", savedIds))
    }

    @Test
    fun savedIncludesOnlyBookmarkedExercises() {
        assertTrue(WorkoutPickerSource.SAVED.includes("Barbell_Squat", savedIds))
        assertFalse(WorkoutPickerSource.SAVED.includes(userExerciseId, savedIds))
    }

    @Test
    fun datasetIncludesEverything() {
        assertTrue(WorkoutPickerSource.DATASET.includes("Barbell_Squat", emptySet()))
        assertTrue(WorkoutPickerSource.DATASET.includes(userExerciseId, emptySet()))
    }

    @Test
    fun storedSourceFallsBackToDataset() {
        assertEquals(WorkoutPickerSource.MINE, WorkoutPickerSource.fromStorage("MINE"))
        assertEquals(WorkoutPickerSource.SAVED, WorkoutPickerSource.fromStorage("SAVED"))
        assertEquals(WorkoutPickerSource.DATASET, WorkoutPickerSource.fromStorage(null))
        assertEquals(WorkoutPickerSource.DATASET, WorkoutPickerSource.fromStorage("UNKNOWN"))
    }
}
