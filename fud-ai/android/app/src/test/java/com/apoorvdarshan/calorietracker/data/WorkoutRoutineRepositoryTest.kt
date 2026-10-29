package com.apoorvdarshan.calorietracker.data

import com.apoorvdarshan.calorietracker.models.WorkoutPersistedState
import com.apoorvdarshan.calorietracker.models.WorkoutWeightUnit
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.util.UUID

class WorkoutRoutineRepositoryTest {
    private val monday = LocalDate.of(2026, 10, 12)
    private val thursday = LocalDate.of(2026, 10, 15)

    private fun item(id: String, name: String) = ExerciseItem(
        id = id,
        name = name,
        level = "Intermediate",
        imagePaths = emptyList(),
        force = "Push",
        mechanic = "Compound",
        category = "Strength",
        equipment = "Barbell",
        primaryMuscles = listOf("Chest"),
        secondaryMuscles = emptyList(),
        instructions = emptyList()
    )

    /** Monday: bench 2 x 10 @ 60 kg (RPE 8) and rows with one blank set. */
    private suspend fun loggedMonday(repository: WorkoutRepository) {
        repository.toggleExercise(item("bench", "Bench Press"), monday)
        repository.toggleExercise(item("row", "Barbell Row"), monday)
        val bench = repository.planNow(monday).exercises.first { it.itemId == "bench" }
        repository.setSetCount(2, bench.id, monday)
        repository.planNow(monday).exercises.first { it.itemId == "bench" }.sets.forEach { set ->
            repository.updateSet(bench.id, set.id, monday, weight = "60", weightUnit = WorkoutWeightUnit.KG, reps = "10", rpe = "8")
        }
    }

    @Test
    fun savingKeepsTheDaysPlanAndRejectsEmptyDaysAndNames() = runBlocking {
        val repository = WorkoutRepository(RoutineStateStore())
        loggedMonday(repository)

        assertNull(repository.saveRoutine("   ", monday))
        assertNull(repository.saveRoutine("Push", thursday))
        val saved = requireNotNull(repository.saveRoutine("  Push   day ", monday, Instant.parse("2026-10-12T18:00:00Z")))

        val routine = repository.snapshot().routines.single()
        assertEquals(saved, routine)
        assertEquals("Push day", routine.name)
        assertEquals(listOf("bench", "row"), routine.exercises.map { it.itemId })
        val benchSets = routine.exercises[0].sets
        assertEquals(listOf("60", "60"), benchSets.map { it.weight })
        assertEquals(listOf("10", "10"), benchSets.map { it.reps })
        assertTrue(benchSets.all { it.rpe.isEmpty() })
        // The day itself is untouched.
        assertEquals("8", repository.planNow(monday).exercises[0].sets[0].rpe)
    }

    @Test
    fun renameAndDeleteChangeOnlyTheRoutine() = runBlocking {
        val repository = WorkoutRepository(RoutineStateStore())
        loggedMonday(repository)
        val first = requireNotNull(repository.saveRoutine("Push", monday))
        val second = requireNotNull(repository.saveRoutine("Pull", monday))

        assertTrue(repository.renameRoutine(first.id, "Push A"))
        assertFalse(repository.renameRoutine(first.id, "  "))
        assertFalse(repository.renameRoutine(UUID.randomUUID(), "Ghost"))
        assertEquals(listOf("Push A", "Pull"), repository.snapshot().routines.map { it.name })

        repository.deleteRoutine(second.id)
        assertEquals(listOf(first.id), repository.snapshot().routines.map { it.id })
        assertEquals(2, repository.planNow(monday).exercises.size)
        assertEquals(listOf(first.id), repository.routines.first().map { it.id })
    }

    @Test
    fun applyingFillsAnEmptyDayAndAppendsWithoutTouchingLoggedSets() = runBlocking {
        val repository = WorkoutRepository(RoutineStateStore())
        loggedMonday(repository)
        val routine = requireNotNull(repository.saveRoutine("Push", monday))

        assertTrue(repository.applyRoutine(routine.id, thursday))
        val thursdayPlan = repository.planNow(thursday).exercises
        assertEquals(listOf("bench", "row"), thursdayPlan.map { it.itemId })
        assertEquals(listOf("60", "60"), thursdayPlan[0].sets.map { it.weight })

        // Friday already has a logged bench set and a blank squat.
        val friday = thursday.plusDays(1)
        repository.toggleExercise(item("bench", "Bench Press"), friday)
        repository.toggleExercise(item("squat", "Squat"), friday)
        val fridayBench = repository.planNow(friday).exercises[0]
        repository.updateSet(fridayBench.id, fridayBench.sets[0].id, friday, weight = "80", weightUnit = WorkoutWeightUnit.KG, reps = "3")
        val loggedBench = repository.planNow(friday).exercises[0]

        assertTrue(repository.applyRoutine(routine.id, friday))
        val fridayPlan = repository.planNow(friday).exercises
        assertEquals(listOf("bench", "squat", "row"), fridayPlan.map { it.itemId })
        assertEquals(loggedBench, fridayPlan[0])

        assertFalse(repository.applyRoutine(UUID.randomUUID(), friday))
    }

    @Test
    fun routinesSurviveEncodingAndOlderDiariesDecodeWithNone() = runBlocking {
        val repository = WorkoutRepository(RoutineStateStore())
        loggedMonday(repository)
        // Stored timestamps keep millisecond precision.
        repository.saveRoutine("Push", monday, Instant.parse("2026-10-12T18:00:00.125Z"))
        val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }
        val state = repository.snapshot()

        val decoded = json.decodeFromString(
            WorkoutPersistedState.serializer(),
            json.encodeToString(WorkoutPersistedState.serializer(), state)
        )
        assertEquals(state.routines, decoded.routines)

        val legacy = json.decodeFromString(
            WorkoutPersistedState.serializer(),
            """{"version":1,"dayPlans":{},"savedExerciseIds":["bench"]}"""
        )
        assertTrue(legacy.routines.isEmpty())
        assertEquals(setOf("bench"), legacy.savedExerciseIds)
        assertEquals(90, legacy.preferences.restTimerSeconds)
    }

    @Test
    fun routinePlansAreIndependentFromTheDayTheyCameFrom() = runBlocking {
        val repository = WorkoutRepository(RoutineStateStore())
        loggedMonday(repository)
        val routine = requireNotNull(repository.saveRoutine("Push", monday))
        val bench = repository.planNow(monday).exercises[0]
        repository.updateSet(bench.id, bench.sets[0].id, monday, reps = "4")

        val stored = repository.snapshot().routines.single { it.id == routine.id }
        assertEquals("10", stored.exercises[0].sets[0].reps)
        assertEquals(listOf("4", "10"), repository.planNow(monday).exercises[0].sets.map { it.reps })
    }
}

private class RoutineStateStore(initial: WorkoutPersistedState = WorkoutPersistedState()) : WorkoutStateStore {
    private val mutable = MutableStateFlow(initial)
    override val workoutState: Flow<WorkoutPersistedState> = mutable

    override suspend fun setWorkoutState(state: WorkoutPersistedState) {
        mutable.value = state
    }

    override suspend fun clearWorkoutState() {
        mutable.value = WorkoutPersistedState()
    }
}
