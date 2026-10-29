package com.apoorvdarshan.calorietracker.models

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.util.UUID

class WorkoutRestTimerTest {
    private val start = Instant.parse("2026-10-18T10:00:00Z")
    private val exerciseId = UUID.fromString("00000000-0000-0000-0000-000000000001")
    private val setId = UUID.fromString("00000000-0000-0000-0000-000000000002")

    private fun timer(seconds: Int = 90) =
        requireNotNull(WorkoutRestTimer.start(exerciseId, setId, "Bench Press", seconds, start))

    @Test
    fun settingIsOffOrClampedToHalfAMinuteThroughFiveMinutes() {
        assertEquals(90, WorkoutRestTimerSetting.DEFAULT_SECONDS)
        assertEquals(0, WorkoutRestTimerSetting.sanitized(0))
        assertEquals(0, WorkoutRestTimerSetting.sanitized(-15))
        assertEquals(30, WorkoutRestTimerSetting.sanitized(10))
        assertEquals(300, WorkoutRestTimerSetting.sanitized(900))
        assertEquals(WorkoutRestTimerSetting.Options, WorkoutRestTimerSetting.Options.map(WorkoutRestTimerSetting::sanitized))
        assertEquals(0, WorkoutRestTimerSetting.Options.first())
        assertEquals(300, WorkoutRestTimerSetting.Options.last())
    }

    @Test
    fun preferencesSavedBeforeTheRestTimerUseTheDefaultAndOutOfRangeValuesAreClamped() {
        val json = Json { ignoreUnknownKeys = true }
        val legacy = json.decodeFromString(WorkoutPreferences.serializer(), """{"frequencyDays":4,"rpeScale":"CR10"}""")
        assertEquals(WorkoutRestTimerSetting.DEFAULT_SECONDS, legacy.restTimerSeconds)
        assertEquals(WorkoutRpeScale.CR10, legacy.rpeScale)

        assertEquals(300, WorkoutPreferences(restTimerSeconds = 1_200).sanitized().restTimerSeconds)
        assertEquals(0, WorkoutPreferences(restTimerSeconds = 0).sanitized().restTimerSeconds)
        val roundTrip = json.decodeFromString(
            WorkoutPreferences.serializer(),
            json.encodeToString(WorkoutPreferences.serializer(), WorkoutPreferences(restTimerSeconds = 45))
        )
        assertEquals(45, roundTrip.restTimerSeconds)
    }

    @Test
    fun startingWithTheTimerOffCreatesNoCountdown() {
        assertNull(WorkoutRestTimer.start(exerciseId, setId, "Bench Press", 0, start))
    }

    @Test
    fun countdownRoundsUpToWholeSecondsAndFinishesAtItsEnd() {
        val rest = timer(90)
        assertEquals(90, rest.remainingSeconds(start))
        assertEquals(90, rest.remainingSeconds(start.plusMillis(200)))
        assertEquals(1, rest.remainingSeconds(start.plusMillis(89_001)))
        assertEquals(0, rest.remainingSeconds(start.plusSeconds(90)))
        assertEquals(0, rest.remainingSeconds(start.plusSeconds(500)))
        assertFalse(rest.isFinished(start.plusMillis(89_999)))
        assertTrue(rest.isFinished(start.plusSeconds(90)))
        assertEquals(0.5f, rest.progress(start.plusSeconds(45)), 0.0001f)
        assertEquals(1f, rest.progress(start.plusSeconds(120)), 0.0001f)
    }

    @Test
    fun addingFifteenSecondsExtendsARunningRestAndRestartsAFinishedOneFromNow() {
        val running = timer(60).extended(at = start.plusSeconds(20))
        assertEquals(start.plusSeconds(75), running.endsAt)
        assertEquals(55, running.remainingSeconds(start.plusSeconds(20)))

        val finished = timer(60).extended(at = start.plusSeconds(100))
        assertEquals(start.plusSeconds(115), finished.endsAt)
    }

    @Test
    fun onlyAJustFinishedRestAlertsInApp() {
        val rest = timer(30)
        assertFalse(rest.shouldAlertInApp(start.plusSeconds(29)))
        assertTrue(rest.shouldAlertInApp(start.plusSeconds(30)))
        assertTrue(rest.shouldAlertInApp(start.plusMillis(32_900)))
        // A rest that ran out while the app was in the background was announced by its notification.
        assertFalse(rest.shouldAlertInApp(start.plusSeconds(60)))
    }

    @Test
    fun loggingASetStartsRestOnlyWhenItsRepsAreFirstFilledInToday() {
        assertTrue(WorkoutRestTimer.shouldStart("", "8", restSeconds = 90, isToday = true))
        assertTrue(WorkoutRestTimer.shouldStart(" ", "12", restSeconds = 90, isToday = true))
        // Editing a logged set, or clearing it, keeps the current rest.
        assertFalse(WorkoutRestTimer.shouldStart("8", "10", restSeconds = 90, isToday = true))
        assertFalse(WorkoutRestTimer.shouldStart("8", "", restSeconds = 90, isToday = true))
        assertFalse(WorkoutRestTimer.shouldStart("", "", restSeconds = 90, isToday = true))
        // Off, or planning/back-filling another day.
        assertFalse(WorkoutRestTimer.shouldStart("", "8", restSeconds = 0, isToday = true))
        assertFalse(WorkoutRestTimer.shouldStart("", "8", restSeconds = 90, isToday = false))
        // A set that already rested is being corrected: clearing its reps and typing them
        // again, or a second keystroke that arrives before the first one is saved.
        assertFalse(WorkoutRestTimer.shouldStart("", "8", restSeconds = 90, isToday = true, alreadyRested = true))
    }

    @Test
    fun addingASetWithTheStepperFinishesThePreviousLoggedSet() {
        val first = PlannedSet(weight = "60", reps = "8")
        val second = first.copyingFromPrevious()
        val third = second.copyingFromPrevious()
        fun finished(
            before: List<PlannedSet>,
            after: List<PlannedSet>,
            restSeconds: Int = 90,
            isToday: Boolean = true,
            running: WorkoutRestTimer? = null,
            at: Instant = start
        ) = WorkoutRestTimer.setFinishedByAddingSets(before, after, restSeconds, isToday, running, at)

        // The new set arrives with the reps already filled in, so typing never starts its rest.
        assertEquals("8", second.reps)
        assertEquals(first.id, finished(listOf(first), listOf(first, second)))
        assertEquals(second.id, finished(listOf(first, second), listOf(first, second, third)))

        // A set whose reps are still blank is not logged yet, and removing or keeping sets logs nothing.
        val blank = PlannedSet()
        assertNull(finished(listOf(blank), listOf(blank, blank.copyingFromPrevious())))
        assertNull(finished(listOf(first, second), listOf(first)))
        assertNull(finished(listOf(first), listOf(first)))
        assertNull(finished(emptyList(), listOf(first)))
        // Off, or planning/back-filling another day.
        assertNull(finished(listOf(first), listOf(first, second), restSeconds = 0))
        assertNull(finished(listOf(first), listOf(first, second), isToday = false))

        // Adding sets ahead while the previous set rests keeps that countdown; once it ran out,
        // or while another set rests, the previous set starts its own rest.
        val resting = requireNotNull(WorkoutRestTimer.start(exerciseId, first.id, "Bench Press", 90, start))
        assertNull(finished(listOf(first), listOf(first, second), running = resting, at = start.plusSeconds(30)))
        assertEquals(first.id, finished(listOf(first), listOf(first, second), running = resting, at = start.plusSeconds(90)))
        assertEquals(second.id, finished(listOf(first, second), listOf(first, second, third), running = resting))
    }

    @Test
    fun clockTextIsMinutesAndPaddedSeconds() {
        assertEquals("1:30", WorkoutRestTimer.clockText(90))
        assertEquals("0:05", WorkoutRestTimer.clockText(5))
        assertEquals("5:00", WorkoutRestTimer.clockText(300))
        assertEquals("0:00", WorkoutRestTimer.clockText(-3))
    }
}
