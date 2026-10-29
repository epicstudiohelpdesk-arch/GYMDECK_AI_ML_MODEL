package com.apoorvdarshan.calorietracker.models

import java.time.Duration
import java.time.Instant
import java.util.Locale
import java.util.UUID

/** The global rest countdown preference in Workouts settings: off, or 30 s to 5 min. */
object WorkoutRestTimerSetting {
    const val DEFAULT_SECONDS = 90
    const val MIN_SECONDS = 30
    const val MAX_SECONDS = 300

    /** 0 means off. */
    val Options: List<Int> = listOf(0, 30, 45, 60, 90, 120, 150, 180, 240, 300)

    fun sanitized(seconds: Int): Int = if (seconds <= 0) 0 else seconds.coerceIn(MIN_SECONDS, MAX_SECONDS)
}

/**
 * One rest period after a logged strength set, matching iOS `WorkoutRestTimer`. Wall-clock
 * anchors keep the countdown exact while the app is in the background.
 */
data class WorkoutRestTimer(
    val exerciseId: UUID,
    val setId: UUID,
    val exerciseName: String,
    val startedAt: Instant,
    val endsAt: Instant
) {
    fun remainingSeconds(at: Instant = Instant.now()): Long {
        val millis = Duration.between(at, endsAt).toMillis()
        return if (millis <= 0) 0 else (millis + 999) / 1_000
    }

    fun isFinished(at: Instant = Instant.now()): Boolean = !at.isBefore(endsAt)

    /** Fraction of the rest already elapsed, 0..1. */
    fun progress(at: Instant = Instant.now()): Float {
        val total = Duration.between(startedAt, endsAt).toMillis()
        if (total <= 0) return 1f
        return (Duration.between(startedAt, at).toMillis().toFloat() / total).coerceIn(0f, 1f)
    }

    /** Adds time to the countdown; once it has already run out it counts again from now. */
    fun extended(seconds: Long = EXTENSION_SECONDS, at: Instant = Instant.now()): WorkoutRestTimer =
        copy(endsAt = maxOf(endsAt, at).plusSeconds(seconds))

    /**
     * The in-app alert is only for a countdown that just ended. One that ran out longer ago
     * ended while the app was in the background, and its notification already announced it.
     */
    fun shouldAlertInApp(at: Instant = Instant.now()): Boolean =
        isFinished(at) && Duration.between(endsAt, at).toMillis() < IN_APP_ALERT_WINDOW_MILLIS

    companion object {
        const val EXTENSION_SECONDS = 15L
        private const val IN_APP_ALERT_WINDOW_MILLIS = 3_000L

        /** Null when the rest timer is off. */
        fun start(
            exerciseId: UUID,
            setId: UUID,
            exerciseName: String,
            durationSeconds: Int,
            at: Instant = Instant.now()
        ): WorkoutRestTimer? {
            if (durationSeconds <= 0) return null
            return WorkoutRestTimer(exerciseId, setId, exerciseName, at, at.plusSeconds(durationSeconds.toLong()))
        }

        /**
         * A set counts as logged once its reps are first filled in, so that edit starts rest.
         * Only today's log rests; planning or back-filling another day does not. A set that
         * already rested is being corrected (its reps cleared and typed again, or a keystroke
         * that arrives before the first one is saved), which leaves the running rest alone.
         */
        fun shouldStart(
            previousReps: String,
            newReps: String,
            restSeconds: Int,
            isToday: Boolean,
            alreadyRested: Boolean = false
        ): Boolean =
            restSeconds > 0 && isToday && !alreadyRested && previousReps.isBlank() && newReps.isNotBlank()

        /**
         * The set stepper adds the next set prefilled from the one before it, so its reps never
         * go from blank to filled. Adding a set with the stepper therefore finishes the previous
         * one: returns that set when its reps are filled in and it should rest now. A rest that
         * is still counting down for it keeps running, so adding sets ahead never restarts it.
         */
        fun setFinishedByAddingSets(
            setsBefore: List<PlannedSet>,
            setsAfter: List<PlannedSet>,
            restSeconds: Int,
            isToday: Boolean,
            running: WorkoutRestTimer?,
            at: Instant = Instant.now()
        ): UUID? {
            val finished = setsBefore.lastOrNull() ?: return null
            if (setsAfter.size <= setsBefore.size || setsAfter.none { it.id == finished.id }) return null
            if (!shouldStart(previousReps = "", newReps = finished.reps, restSeconds = restSeconds, isToday = isToday)) {
                return null
            }
            if (running != null && running.setId == finished.id && !running.isFinished(at)) return null
            return finished.id
        }

        /** "m:ss", the same in every language. */
        fun clockText(seconds: Long): String {
            val safe = seconds.coerceAtLeast(0)
            return String.format(Locale.US, "%d:%02d", safe / 60, safe % 60)
        }
    }
}
