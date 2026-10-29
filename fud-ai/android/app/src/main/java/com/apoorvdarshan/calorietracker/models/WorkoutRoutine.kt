package com.apoorvdarshan.calorietracker.models

import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.UUID

/**
 * A named, reusable exercise list saved from a diary day, with each exercise's planned sets,
 * reps and loads. Mirrors iOS `StrengthWorkoutRoutine`.
 */
@Serializable
data class WorkoutRoutine(
    @Serializable(with = UuidSerializer::class)
    val id: UUID = UUID.randomUUID(),
    val name: String,
    val exercises: List<PlannedExercise>,
    @Serializable(with = InstantSerializer::class)
    val createdAt: Instant
) {
    val exerciseSummary: String get() = exercises.joinToString { it.name }
}

/** Save and merge rules shared with iOS `StrengthWorkoutRoutinePlanner`. */
object WorkoutRoutinePlanner {
    const val MAX_NAME_LENGTH = 60

    /** Trims, collapses inner whitespace and caps the length. */
    fun sanitizedName(name: String): String =
        name.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ").take(MAX_NAME_LENGTH)

    /**
     * The day's exercises as a plan: fresh identities, the planned load, unit and reps of every
     * set. RPE (how a set felt) and exercise timers belong to the day they were logged.
     */
    fun template(exercises: List<PlannedExercise>): List<PlannedExercise> = exercises.map { exercise ->
        val copy = exercise.copiedForNewDay(includeSetDetails = true).copy(timer = null)
        if (copy.isCardio) {
            // Cardio cards have no set fields; keep the shape of a newly picked exercise.
            copy.copy(sets = listOf(PlannedSet()))
        } else {
            val sets = copy.sets.map { PlannedSet(weight = it.weight, weightUnit = it.weightUnit, reps = it.reps) }
            copy.copy(sets = sets.ifEmpty { listOf(PlannedSet()) })
        }
    }

    /**
     * Adds a routine to a day without touching anything already logged there.
     *
     * Each routine exercise is matched, in order, to an unmatched entry of the same exercise
     * already on the day. A matched entry that holds no logged value yet (no weight, reps or RPE
     * and no started timer) takes the routine's planned sets; one with logged work is left
     * exactly as it is. Routine exercises with no match are appended as new entries.
     */
    fun merged(day: List<PlannedExercise>, routine: List<PlannedExercise>): List<PlannedExercise> {
        val result = day.toMutableList()
        val matchedDayIndices = mutableSetOf<Int>()
        for (template in routine) {
            val index = day.indices.firstOrNull { it !in matchedDayIndices && day[it].itemId == template.itemId }
            if (index != null) {
                matchedDayIndices += index
                if (canReceivePlan(result[index])) {
                    result[index] = result[index].copy(sets = template.copiedForNewDay(includeSetDetails = true).sets)
                }
            } else {
                result += template.copiedForNewDay(includeSetDetails = true).copy(timer = null)
            }
        }
        return result
    }

    /** True while a day entry holds nothing the user logged. */
    fun canReceivePlan(exercise: PlannedExercise): Boolean =
        exercise.sets.none { it.hasLoggedValue } && exercise.timer?.hasStarted != true
}
