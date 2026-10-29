package com.apoorvdarshan.calorietracker.data

import androidx.health.connect.client.records.ExerciseSessionRecord
import com.apoorvdarshan.calorietracker.models.ImportedHealthWorkout
import com.apoorvdarshan.calorietracker.models.importedWorkoutsOn
import com.apoorvdarshan.calorietracker.services.health.HealthExerciseSession
import com.apoorvdarshan.calorietracker.services.health.SessionCalorieLookup
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Health Connect workout import (#479), Android port of iOS ImportedHealthWorkoutStore. */
class ImportedHealthWorkoutRepositoryTest {
    private val now = Instant.parse("2026-10-18T12:00:00Z")
    private val zone = ZoneId.of("Asia/Kolkata")

    @Test
    fun sessionMapsToReadOnlyWorkoutOnItsLocalDiaryDay() {
        // 23:00 UTC on Oct 11 is already Oct 12 in India.
        val session = session("run", start = "2026-10-11T23:00:00Z", minutes = 47, laps = 7_520.0)

        val workout = session.toImportedHealthWorkout(zone, "Garmin Connect", 512, 99L)!!

        assertEquals("run", workout.id)
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_RUNNING, workout.exerciseType)
        assertEquals("2026-10-12", workout.diaryDateKey)
        assertEquals(47 * 60, workout.durationSeconds)
        assertEquals(47, workout.durationMinutes)
        assertEquals(512, workout.activeCalories)
        assertEquals(7_520.0, workout.distanceMeters!!, 0.0)
        assertEquals("Garmin Connect · Garmin Forerunner 265", workout.sourceSummary)
        assertEquals(99L, workout.caloriesCheckedForModifiedMs)
    }

    @Test
    fun unresolvedAppNameFallsBackToThePackageAndZeroCaloriesReadAsUnknown() {
        val workout = session("walk", device = null).toImportedHealthWorkout(zone, "  ", 0, null)!!

        assertEquals("com.strava", workout.sourceSummary)
        assertNull(workout.activeCalories)
    }

    @Test
    fun deniedExercisePermissionClearsImportsWithoutReadingHealthConnect() = runBlocking {
        val store = FakeImportedStore(listOf(stored("old")))
        val source = FakeSource(granted = false)

        val result = repository(store, source).synchronize()

        assertEquals(HealthWorkoutImportResult.PERMISSION_DENIED, result)
        assertTrue(store.items.value.isEmpty())
        assertEquals(0, source.sessionReads)
        assertEquals(0, source.calorieLookups)
    }

    @Test
    fun revokedAccessRemovesImportsOutsideTheSync() = runBlocking {
        // Every Fud AI permission revoked, or Exercise revoked while Fud AI's Health Connect
        // toggle is off: the foreground sync returns before synchronize(), so removal runs on
        // its own and must not need any other permission.
        val store = FakeImportedStore(listOf(stored("garmin-run"), stored("strava-ride")))
        val source = FakeSource(granted = false)

        assertTrue(repository(store, source).removeIfAccessRevoked())

        assertTrue(store.items.value.isEmpty())
        assertEquals(0, source.sessionReads)
        assertEquals(0, source.calorieLookups)
    }

    @Test
    fun removalKeepsImportsWhenAccessRemainsOrTheProbeFails() = runBlocking {
        val kept = listOf(stored("garmin-run"))

        // Still granted (e.g. only Fud AI's toggle is off): kept, and nothing is imported.
        val granted = FakeImportedStore(kept)
        val grantedSource = FakeSource(sessions = listOf(session("new")))
        assertFalse(repository(granted, grantedSource).removeIfAccessRevoked())
        assertEquals(kept, granted.items.value)
        assertEquals(0, grantedSource.sessionReads)

        // A failed probe or unavailable Health Connect is not a revocation.
        val probeFailed = FakeImportedStore(kept)
        assertFalse(repository(probeFailed, FakeSource(granted = null)).removeIfAccessRevoked())
        assertEquals(kept, probeFailed.items.value)
    }

    @Test
    fun removalDoesNotProbeWhenNothingWasImported() = runBlocking {
        val source = FakeSource(granted = false)

        assertFalse(repository(FakeImportedStore(), source).removeIfAccessRevoked())

        assertEquals(0, source.permissionProbes)
    }

    @Test
    fun failedPermissionProbeOrReadKeepsStoredImports() = runBlocking {
        val kept = listOf(stored("old"))
        val probeFailed = FakeImportedStore(kept)
        assertEquals(
            HealthWorkoutImportResult.SKIPPED,
            repository(probeFailed, FakeSource(granted = null)).synchronize()
        )
        assertEquals(kept, probeFailed.items.value)

        val readFailed = FakeImportedStore(kept)
        assertEquals(
            HealthWorkoutImportResult.SKIPPED,
            repository(readFailed, FakeSource(sessions = null)).synchronize()
        )
        assertEquals(kept, readFailed.items.value)
    }

    @Test
    fun syncImportsSessionsWithCaloriesAndAppNames() = runBlocking {
        val store = FakeImportedStore()
        val source = FakeSource(
            sessions = listOf(session("ride", start = "2026-10-10T05:00:00Z")),
            calories = mapOf("ride" to SessionCalorieLookup.Resolved(640))
        )

        assertEquals(HealthWorkoutImportResult.SYNCED, repository(store, source).synchronize())

        val workout = store.items.value.single()
        assertEquals(640, workout.activeCalories)
        assertEquals("Strava", workout.sourceName)
        assertEquals(session("ride", start = "2026-10-10T05:00:00Z").lastModified.toEpochMilli(), workout.caloriesCheckedForModifiedMs)
    }

    @Test
    fun unchangedOlderSessionsReuseStoredCaloriesWhileRecentOnesAreRechecked() = runBlocking {
        val older = session("older", start = "2026-10-10T05:00:00Z")
        val recent = session("recent", start = "2026-10-17T18:00:00Z")
        val store = FakeImportedStore()
        val source = FakeSource(
            sessions = listOf(older, recent),
            calories = mapOf(
                "older" to SessionCalorieLookup.Resolved(300),
                "recent" to SessionCalorieLookup.Resolved(null)
            )
        )
        val repository = repository(store, source)
        repository.synchronize()
        assertEquals(2, source.calorieLookups)

        // The watch app finishes writing the recent workout's calories after the session.
        source.calories = mapOf("recent" to SessionCalorieLookup.Resolved(410))
        repository.synchronize()

        assertEquals(3, source.calorieLookups)
        assertEquals(300, store.items.value.first { it.id == "older" }.activeCalories)
        assertEquals(410, store.items.value.first { it.id == "recent" }.activeCalories)
    }

    @Test
    fun editedSessionIsLookedUpAgain() = runBlocking {
        val original = session("swim", start = "2026-10-01T05:00:00Z")
        val store = FakeImportedStore()
        val source = FakeSource(sessions = listOf(original), calories = mapOf("swim" to SessionCalorieLookup.Resolved(200)))
        val repository = repository(store, source)
        repository.synchronize()

        source.sessions = listOf(original.copy(lastModified = original.lastModified.plusSeconds(60)))
        source.calories = mapOf("swim" to SessionCalorieLookup.Resolved(260))
        repository.synchronize()

        assertEquals(2, source.calorieLookups)
        assertEquals(260, store.items.value.single().activeCalories)
    }

    @Test
    fun failedOrUnpermittedCalorieLookupKeepsTheLastValueAndRetries() = runBlocking {
        val swim = session("swim", start = "2026-10-01T05:00:00Z")
        val store = FakeImportedStore(listOf(stored("swim", calories = 180, checkedFor = 1L)))
        val source = FakeSource(sessions = listOf(swim), calories = mapOf("swim" to SessionCalorieLookup.Failed))
        val repository = repository(store, source)

        repository.synchronize()
        assertEquals(180, store.items.value.single().activeCalories)
        assertNotEquals(swim.lastModified.toEpochMilli(), store.items.value.single().caloriesCheckedForModifiedMs)

        // Without Active Calories read access no aggregate is attempted; the session waits for it.
        source.activeCaloriesReadable = false
        repository.synchronize()
        assertEquals(1, source.calorieLookups)
        assertNotEquals(swim.lastModified.toEpochMilli(), store.items.value.single().caloriesCheckedForModifiedMs)

        source.activeCaloriesReadable = true
        source.calories = mapOf("swim" to SessionCalorieLookup.Resolved(195))
        repository.synchronize()
        assertEquals(195, store.items.value.single().activeCalories)
    }

    @Test
    fun sessionsDeletedInTheirAppDisappearWhileOlderHistoryStays() = runBlocking {
        val queryStart = now.minus(Duration.ofDays(ImportedHealthWorkoutRepository.LOOKBACK_DAYS))
        val beforeWindow = stored("archived", startedAt = queryStart.minus(Duration.ofDays(3)))
        val deleted = stored("deleted", startedAt = Instant.parse("2026-10-05T05:00:00Z"))
        val store = FakeImportedStore(listOf(beforeWindow, deleted))
        val source = FakeSource(sessions = listOf(session("kept", start = "2026-10-06T05:00:00Z")))

        repository(store, source).synchronize()

        assertEquals(listOf("kept", "archived"), store.items.value.map { it.id })
        assertEquals(queryStart, source.lastQuery?.first)
    }

    @Test
    fun workoutRecordedByTwoAppsIsImportedOnce() = runBlocking {
        // Strava copies the Garmin activity and writes its own session a few minutes later.
        val garmin = session("garmin-run", start = "2026-10-12T06:30:00Z", minutes = 60, origin = "com.garmin.android.apps.connectmobile")
        val strava = session("strava-run", start = "2026-10-12T06:31:00Z", minutes = 58, origin = "com.strava")
            .copy(lastModified = garmin.lastModified.plusSeconds(300))
        val store = FakeImportedStore()
        val source = FakeSource(
            sessions = listOf(strava, garmin),
            calories = mapOf("garmin-run" to SessionCalorieLookup.Resolved(620), "strava-run" to SessionCalorieLookup.Resolved(615))
        )

        repository(store, source).synchronize()

        val workout = store.items.value.single()
        assertEquals("garmin-run", workout.id)
        assertEquals(620, workout.activeCalories)
        assertEquals(1, source.calorieLookups)
    }

    @Test
    fun alreadyImportedCopyStaysWhenTheSameWorkoutArrivesFromAnotherApp() = runBlocking {
        val strava = session("strava-run", start = "2026-10-12T06:30:00Z", minutes = 60, origin = "com.strava")
        val store = FakeImportedStore()
        val source = FakeSource(sessions = listOf(strava), calories = mapOf("strava-run" to SessionCalorieLookup.Resolved(600)))
        val repository = repository(store, source)
        repository.synchronize()

        // Garmin Connect syncs later but wrote its session first.
        val garmin = session("garmin-run", start = "2026-10-12T06:30:00Z", minutes = 60, origin = "com.garmin.android.apps.connectmobile")
            .copy(lastModified = strava.lastModified.minusSeconds(600))
        source.sessions = listOf(strava, garmin)
        repository.synchronize()

        assertEquals(listOf("strava-run"), store.items.value.map { it.id })
    }

    @Test
    fun overlappingSessionsNeverCountTheSameTimeTwice() = runBlocking {
        // A hike, a walk recorded wholly inside it, and a ride that starts before the hike ends.
        val hike = session("hike", start = "2026-10-12T06:00:00Z", minutes = 120, origin = "com.garmin.android.apps.connectmobile")
        val walk = session("walk", start = "2026-10-12T06:30:00Z", minutes = 20, origin = "com.sec.android.app.shealth")
        val ride = session("ride", start = "2026-10-12T07:30:00Z", minutes = 90, origin = "com.strava")
        val store = FakeImportedStore()
        val source = FakeSource(
            sessions = listOf(hike, walk, ride),
            calories = mapOf("hike" to SessionCalorieLookup.Resolved(700), "ride" to SessionCalorieLookup.Resolved(400))
        )

        repository(store, source).synchronize()

        // The walk's time already belongs to the hike: no lookup, no calories of its own.
        assertEquals(setOf("hike", "ride"), source.lookupWindows.keys)
        assertEquals(hike.startTime, source.lookupWindows["hike"])
        // The ride's calories start where the hike ends.
        assertEquals(hike.endTime, source.lookupWindows["ride"])
        val byId = store.items.value.associateBy { it.id }
        assertEquals(setOf("hike", "walk", "ride"), byId.keys)
        assertNull(byId.getValue("walk").activeCalories)
        assertEquals(400, byId.getValue("ride").activeCalories)
    }

    @Test
    fun calorieWindowChangeTriggersANewLookup() = runBlocking {
        val ride = session("ride", start = "2026-10-01T07:30:00Z", minutes = 90)
        val store = FakeImportedStore()
        val source = FakeSource(sessions = listOf(ride), calories = mapOf("ride" to SessionCalorieLookup.Resolved(500)))
        val repository = repository(store, source)
        repository.synchronize()

        // An earlier, partly overlapping session shows up: the ride's window shrinks.
        val run = session("run", start = "2026-10-01T07:00:00Z", minutes = 45, origin = "com.garmin.android.apps.connectmobile")
        source.sessions = listOf(ride, run)
        source.calories = mapOf("ride" to SessionCalorieLookup.Resolved(410), "run" to SessionCalorieLookup.Resolved(300))
        repository.synchronize()

        assertEquals(run.endTime, source.lookupWindows["ride"])
        assertEquals(410, store.items.value.first { it.id == "ride" }.activeCalories)
    }

    @Test
    fun nestedSessionKeepsItsCaloriesUntilTheEnclosingSessionShowsThem() = runBlocking {
        val walk = session("walk", start = "2026-10-12T06:30:00Z", minutes = 20, origin = "com.sec.android.app.shealth")
        val store = FakeImportedStore()
        val source = FakeSource(sessions = listOf(walk), calories = mapOf("walk" to SessionCalorieLookup.Resolved(90)))
        val repository = repository(store, source)
        repository.synchronize()

        // Garmin Connect syncs a hike around the walk later, and its first lookup fails.
        val hike = session("hike", start = "2026-10-12T06:00:00Z", minutes = 120, origin = "com.garmin.android.apps.connectmobile")
        source.sessions = listOf(walk, hike)
        source.calories = mapOf("hike" to SessionCalorieLookup.Failed)
        repository.synchronize()
        assertEquals(90, store.items.value.first { it.id == "walk" }.activeCalories)
        assertNull(store.items.value.first { it.id == "hike" }.activeCalories)

        // Once the hike's calories cover that time, the walk stops counting it.
        source.calories = mapOf("hike" to SessionCalorieLookup.Resolved(700))
        repository.synchronize()
        assertNull(store.items.value.first { it.id == "walk" }.activeCalories)
        assertEquals(700, store.items.value.first { it.id == "hike" }.activeCalories)
    }

    @Test
    fun caloriesFromAWiderWindowAreNotShownOnceTheWindowShrinks() = runBlocking {
        val ride = session("ride", start = "2026-10-01T07:30:00Z", minutes = 90)
        val store = FakeImportedStore()
        val source = FakeSource(sessions = listOf(ride), calories = mapOf("ride" to SessionCalorieLookup.Resolved(500)))
        val repository = repository(store, source)
        repository.synchronize()

        // An earlier run now claims 07:30-07:45, and the ride's new lookup fails: its 500 kcal
        // still include that time, so they wait for the lookup instead of counting it twice.
        val run = session("run", start = "2026-10-01T07:00:00Z", minutes = 45, origin = "com.garmin.android.apps.connectmobile")
        source.sessions = listOf(ride, run)
        source.calories = mapOf("ride" to SessionCalorieLookup.Failed, "run" to SessionCalorieLookup.Resolved(300))
        repository.synchronize()
        assertNull(store.items.value.first { it.id == "ride" }.activeCalories)
        assertEquals(300, store.items.value.first { it.id == "run" }.activeCalories)

        source.calories = mapOf("ride" to SessionCalorieLookup.Resolved(410))
        repository.synchronize()
        assertEquals(410, store.items.value.first { it.id == "ride" }.activeCalories)
        assertEquals(300, store.items.value.first { it.id == "run" }.activeCalories)
    }

    @Test
    fun everySessionGetsALookupEvenWhenMoreThanOneSyncsBudgetNeedOne() = runBlocking {
        val budget = ImportedHealthWorkoutRepository.MAX_CALORIE_LOOKUPS_PER_SYNC
        // More sessions than one sync may look up, one a day so none overlap.
        val sessions = (0 until budget + 25).map { day ->
            session("s$day", start = now.minus(Duration.ofDays(day + 3L)).toString(), minutes = 30)
        }
        val store = FakeImportedStore()
        // Every lookup fails, the worst case for starvation: a failed session stays pending.
        val source = FakeSource(sessions = sessions, calories = sessions.associate { it.recordId to SessionCalorieLookup.Failed })
        val repository = repository(store, source)

        repository.synchronize()
        assertEquals(budget, source.calorieLookups)
        // The newest sessions go first on the first sync...
        assertTrue(sessions.take(budget).all { it.recordId in source.lookupWindows })

        // ...and the 25 never checked go ahead of the ones that just failed on the next.
        source.lookupWindows.clear()
        repository.synchronize()
        assertTrue(sessions.drop(budget).all { it.recordId in source.lookupWindows })
        assertEquals(budget * 2, source.calorieLookups)
    }

    @Test
    fun olderSessionsAreRefreshedPeriodically() = runBlocking {
        // Another app adds the calorie records days after the (unchanged) session.
        var clock = now
        val swim = session("swim", start = "2026-10-01T05:00:00Z")
        val store = FakeImportedStore()
        val source = FakeSource(sessions = listOf(swim))
        val repository = ImportedHealthWorkoutRepository(store, source, now = { clock }, zone = { zone })
        repository.synchronize()
        assertNull(store.items.value.single().activeCalories)

        source.calories = mapOf("swim" to SessionCalorieLookup.Resolved(240))
        clock = now.plus(Duration.ofDays(3))
        repository.synchronize()
        assertEquals(1, source.calorieLookups)

        clock = now.plus(ImportedHealthWorkoutRepository.CALORIE_REFRESH_INTERVAL)
        repository.synchronize()
        assertEquals(2, source.calorieLookups)
        assertEquals(240, store.items.value.single().activeCalories)
    }

    @Test
    fun importRunningWhenAllDataIsDeletedDoesNotWriteSessionsBack() = runBlocking {
        val store = FakeImportedStore(listOf(stored("old")))
        val source = FakeSource(sessions = listOf(session("run")))
        // Delete All Data runs while the import is reading Health Connect: it clears the
        // store and Fud AI's Health Connect toggle with every other setting.
        source.onRead = {
            store.items.value = emptyList()
            store.syncEnabled = false
        }

        assertEquals(HealthWorkoutImportResult.SKIPPED, repository(store, source).synchronize())

        assertTrue(store.items.value.isEmpty())
    }

    @Test
    fun diaryShowsOnlyTheSelectedDaysSessionsEarliestFirst() {
        val late = stored("late", startedAt = Instant.parse("2026-10-12T12:00:00Z"), day = "2026-10-12")
        val early = stored("early", startedAt = Instant.parse("2026-10-12T02:00:00Z"), day = "2026-10-12")
        val other = stored("other", startedAt = Instant.parse("2026-10-11T02:00:00Z"), day = "2026-10-11")

        assertEquals(
            listOf("early", "late"),
            importedWorkoutsOn(listOf(late, other, early), LocalDate.parse("2026-10-12")).map { it.id }
        )
    }

    @Test
    fun newestFirstOrderIsPublished() = runBlocking {
        val store = FakeImportedStore(
            listOf(
                stored("a", startedAt = Instant.parse("2026-10-01T05:00:00Z")),
                stored("b", startedAt = Instant.parse("2026-10-03T05:00:00Z"))
            )
        )

        assertEquals(listOf("b", "a"), repository(store, FakeSource()).workouts.first().map { it.id })
    }

    private fun repository(store: FakeImportedStore, source: FakeSource) =
        ImportedHealthWorkoutRepository(store, source, now = { now }, zone = { zone })

    private fun session(
        id: String,
        start: String = "2026-10-12T06:30:00Z",
        minutes: Long = 45,
        laps: Double? = null,
        device: String? = "Garmin Forerunner 265",
        origin: String = "com.strava"
    ): HealthExerciseSession {
        val startTime = Instant.parse(start)
        return HealthExerciseSession(
            recordId = id,
            exerciseType = ExerciseSessionRecord.EXERCISE_TYPE_RUNNING,
            startTime = startTime,
            endTime = startTime.plus(Duration.ofMinutes(minutes)),
            originPackage = origin,
            lastModified = startTime.plus(Duration.ofMinutes(minutes + 5)),
            deviceName = device,
            lapDistanceMeters = laps
        )
    }

    private fun stored(
        id: String,
        startedAt: Instant = Instant.parse("2026-10-12T06:30:00Z"),
        day: String = "2026-10-12",
        calories: Int? = 250,
        checkedFor: Long? = null
    ) = ImportedHealthWorkout(
        id = id,
        exerciseType = ExerciseSessionRecord.EXERCISE_TYPE_WALKING,
        startedAt = startedAt,
        endedAt = startedAt.plus(Duration.ofMinutes(30)),
        durationSeconds = 1_800,
        activeCalories = calories,
        sourcePackage = "com.strava",
        sourceName = "Strava",
        diaryDateKey = day,
        caloriesCheckedForModifiedMs = checkedFor,
        // A stored value covers the window it was resolved over.
        caloriesWindowStartMs = startedAt.toEpochMilli().takeIf { calories != null }
    )

    private class FakeImportedStore(initial: List<ImportedHealthWorkout> = emptyList()) : ImportedHealthWorkoutStore {
        val items = MutableStateFlow(initial)
        /** Fud AI's Health Connect toggle. */
        var syncEnabled = true
        override val importedHealthWorkouts: Flow<List<ImportedHealthWorkout>> = items
        override suspend fun updateImportedHealthWorkouts(
            transform: (List<ImportedHealthWorkout>) -> List<ImportedHealthWorkout>
        ) {
            items.value = transform(items.value)
        }

        override suspend fun updateImportedHealthWorkoutsIfSyncEnabled(
            transform: (List<ImportedHealthWorkout>) -> List<ImportedHealthWorkout>
        ): Boolean {
            if (!syncEnabled) return false
            items.value = transform(items.value)
            return true
        }
    }

    private class FakeSource(
        var granted: Boolean? = true,
        var sessions: List<HealthExerciseSession>? = emptyList(),
        var calories: Map<String, SessionCalorieLookup> = emptyMap(),
        var activeCaloriesReadable: Boolean = true
    ) : ExerciseSessionSource {
        var permissionProbes = 0
        var sessionReads = 0
        var calorieLookups = 0
        /** Calorie window start passed for each session looked up. */
        val lookupWindows = mutableMapOf<String, Instant>()
        var lastQuery: Pair<Instant, Instant>? = null
        var onRead: () -> Unit = {}

        override suspend fun exerciseReadGranted(): Boolean? {
            permissionProbes++
            return granted
        }
        override suspend fun activeCaloriesReadable(): Boolean = activeCaloriesReadable
        override suspend fun readSessions(from: Instant, to: Instant): List<HealthExerciseSession>? {
            sessionReads++
            lastQuery = from to to
            onRead()
            return sessions
        }

        override suspend fun activeCalories(session: HealthExerciseSession, from: Instant): SessionCalorieLookup {
            calorieLookups++
            lookupWindows[session.recordId] = from
            return calories[session.recordId] ?: SessionCalorieLookup.Resolved(null)
        }

        override fun appLabel(packageName: String): String? = if (packageName == "com.strava") "Strava" else null
    }
}
