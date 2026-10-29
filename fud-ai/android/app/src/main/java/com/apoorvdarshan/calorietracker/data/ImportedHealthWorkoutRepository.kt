package com.apoorvdarshan.calorietracker.data

import com.apoorvdarshan.calorietracker.models.ImportedHealthWorkout
import com.apoorvdarshan.calorietracker.services.health.HealthExerciseSession
import com.apoorvdarshan.calorietracker.services.health.SessionCalorieLookup
import com.apoorvdarshan.calorietracker.services.health.calorieWindowOrder
import com.apoorvdarshan.calorietracker.services.health.calorieWindowStarts
import com.apoorvdarshan.calorietracker.services.health.withoutDuplicateSessions
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Duration
import java.time.Instant
import java.time.ZoneId

/** Health Connect side of the workout import: HealthConnectManager in the app, a fake in tests. */
interface ExerciseSessionSource {
    /** Whether exercise sessions may be read; null when the permission probe failed. */
    suspend fun exerciseReadGranted(): Boolean?

    /** Whether Active Calories Burned may be read for session calories. */
    suspend fun activeCaloriesReadable(): Boolean

    /** Other apps' sessions in [from, to), Fud AI's own left out; null when a read failed. */
    suspend fun readSessions(from: Instant, to: Instant): List<HealthExerciseSession>?

    /** Active calories over [from, session end); [from] is the session start or later. */
    suspend fun activeCalories(session: HealthExerciseSession, from: Instant): SessionCalorieLookup

    /** The recording app's name on this phone, if Android can resolve it. */
    fun appLabel(packageName: String): String?
}

/** Persistence for imported sessions (DataStore in the app). */
interface ImportedHealthWorkoutStore {
    val importedHealthWorkouts: Flow<List<ImportedHealthWorkout>>

    /** Unconditional; removes imports. */
    suspend fun updateImportedHealthWorkouts(
        transform: (List<ImportedHealthWorkout>) -> List<ImportedHealthWorkout>
    )

    /**
     * Applies [transform] only while Fud AI's Health Connect sync is on, checked in the same
     * transaction as the write, and returns whether it ran. Delete All Data wipes that setting
     * with everything else, so an import already reading Health Connect when the user deletes
     * everything cannot write its sessions back afterwards.
     */
    suspend fun updateImportedHealthWorkoutsIfSyncEnabled(
        transform: (List<ImportedHealthWorkout>) -> List<ImportedHealthWorkout>
    ): Boolean
}

/** What one [ImportedHealthWorkoutRepository.synchronize] call did. */
enum class HealthWorkoutImportResult {
    /** The permission probe or session read failed, or Health Connect sync was turned off
     *  (or all data deleted) mid-import; stored sessions were left untouched. */
    SKIPPED,
    /** Exercise access is not granted; any imported copies were removed. */
    PERMISSION_DENIED,
    SYNCED
}

/**
 * Read-only copies of exercise sessions other apps (Garmin Connect, Coros, Strava, Samsung
 * Health, Fitbit, …) shared with Health Connect, shown in the Workouts diary and on Progress.
 * Port of iOS ImportedHealthWorkoutStore + HealthKitManager's workout import: rows are keyed
 * by Health Connect record id (one row per workout when several apps recorded it), refreshed
 * over a rolling [LOOKBACK_DAYS] window, never written back, and never fed into Fud AI's
 * calculated burns or Energy Burn goals.
 */
class ImportedHealthWorkoutRepository(
    private val store: ImportedHealthWorkoutStore,
    private val source: ExerciseSessionSource,
    private val now: () -> Instant = Instant::now,
    private val zone: () -> ZoneId = ZoneId::systemDefault
) {
    private val mutex = Mutex()

    /** Newest first. */
    val workouts: Flow<List<ImportedHealthWorkout>> = store.importedHealthWorkouts.map { list ->
        list.sortedWith(newestFirst)
    }

    /**
     * Removes the imported copies once a successful permission probe shows Exercise access is
     * gone, and never imports. It needs no other Health Connect permission and ignores Fud AI's
     * Health Connect toggle, so the foreground sync runs it ahead of those guards: revoking every
     * Fud AI permission, or Exercise while the toggle is off, skips [synchronize] but must still
     * remove them. A failed probe keeps them; with nothing imported it does not probe at all.
     * Returns whether copies were removed.
     */
    suspend fun removeIfAccessRevoked(): Boolean = mutex.withLock {
        if (store.importedHealthWorkouts.first().isEmpty()) return@withLock false
        if (source.exerciseReadGranted() != false) return@withLock false
        clearImports()
        true
    }

    suspend fun synchronize(): HealthWorkoutImportResult = mutex.withLock {
        val granted = source.exerciseReadGranted() ?: return@withLock HealthWorkoutImportResult.SKIPPED
        if (!granted) {
            // Access was declined or revoked: drop the copies made while it was granted.
            clearImports()
            return@withLock HealthWorkoutImportResult.PERMISSION_DENIED
        }

        val end = now()
        val queryStart = end.minus(Duration.ofDays(LOOKBACK_DAYS))
        val read = source.readSessions(queryStart, end) ?: return@withLock HealthWorkoutImportResult.SKIPPED
        val previous = store.importedHealthWorkouts.first().associateBy { it.id }
        // One row per workout, even when two apps recorded it (Garmin Connect and Strava).
        val sessions = withoutDuplicateSessions(read, previous.keys)
        // Sessions that still overlap split the shared time, so no calories count twice.
        val windowStarts = calorieWindowStarts(sessions)
        val nowMs = end.toEpochMilli()

        // Least recently checked first (never-checked sessions first, newest first among
        // them), so sessions beyond one sync's budget, or behind ones whose lookups keep
        // failing, still get their turn on a later sync.
        val lookUp: Set<String> = if (source.activeCaloriesReadable()) {
            sessions
                .filter { session ->
                    val from = windowStarts.getValue(session.recordId)
                    from.isBefore(session.endTime) &&
                        needsCalorieLookup(previous[session.recordId], session, from, end)
                }
                .sortedWith(
                    compareBy<HealthExerciseSession> {
                        previous[it.recordId]?.caloriesCheckedAtEpochMs ?: Long.MIN_VALUE
                    }.thenByDescending { it.startTime }.thenBy { it.recordId }
                )
                .take(MAX_CALORIE_LOOKUPS_PER_SYNC)
                .mapTo(HashSet()) { it.recordId }
        } else {
            emptySet()
        }

        val fresh = HashMap<String, CalorieCheck>()
        val failed = HashSet<String>()
        for (session in sessions) {
            if (session.recordId !in lookUp) continue
            val from = windowStarts.getValue(session.recordId)
            when (val lookup = source.activeCalories(session, from)) {
                is SessionCalorieLookup.Resolved -> fresh[session.recordId] =
                    CalorieCheck(lookup.activeCalories, session.lastModified.toEpochMilli(), from.toEpochMilli(), nowMs)
                SessionCalorieLookup.Failed -> failed += session.recordId
            }
        }

        // What each row shows, earliest first. A shown value covers its window from
        // windowStartMs to the session's end; no two shown windows may overlap, so a value
        // left over from a wider window waits for its lookup instead of counting shared time
        // twice, and time counts as covered by an earlier session only once that session
        // shows a value for it.
        val checks = HashMap<String, CalorieCheck>()
        var shownUntil: Instant? = null
        for (session in sessions.sortedWith(calorieWindowOrder)) {
            val id = session.recordId
            val stored = previous[id]
            val kept = CalorieCheck(
                calories = stored?.activeCalories,
                checkedForModifiedMs = stored?.caloriesCheckedForModifiedMs,
                windowStartMs = stored?.caloriesWindowStartMs,
                // A failed lookup retries behind sessions not tried as recently.
                checkedAtMs = if (id in failed) nowMs else stored?.caloriesCheckedAtEpochMs
            )
            val shown = shownUntil
            val check = fresh[id] ?: when {
                // Wholly inside earlier sessions whose shown calories already cover this time.
                !windowStarts.getValue(id).isBefore(session.endTime) &&
                    shown != null && !shown.isBefore(session.endTime) ->
                    CalorieCheck(null, session.lastModified.toEpochMilli(), session.endTime.toEpochMilli(), nowMs)
                kept.windowStartMs != null && (shown == null || kept.windowStartMs >= shown.toEpochMilli()) -> kept
                // Unknown until a lookup resolves its current window.
                else -> CalorieCheck(null, null, null, kept.checkedAtMs)
            }
            checks[id] = check
            if (check.windowStartMs != null && (shown == null || session.endTime.isAfter(shown))) {
                shownUntil = session.endTime
            }
        }

        val labels = mutableMapOf<String, String?>()
        val zoneId = zone()
        val fetched = sessions.mapNotNull { session ->
            val stored = previous[session.recordId]
            val check = checks.getValue(session.recordId)
            val origin = session.originPackage
            val label = if (origin in labels) labels[origin] else source.appLabel(origin).also { labels[origin] = it }
            session.toImportedHealthWorkout(
                zoneId,
                label ?: stored?.sourceName,
                check.calories,
                check.checkedForModifiedMs,
                check.windowStartMs,
                check.checkedAtMs
            )
        }

        val written = store.updateImportedHealthWorkoutsIfSyncEnabled { current ->
            reconcileImportedWorkouts(current, fetched, queryStart)
        }
        if (written) HealthWorkoutImportResult.SYNCED else HealthWorkoutImportResult.SKIPPED
    }

    private data class CalorieCheck(
        val calories: Int?,
        val checkedForModifiedMs: Long?,
        val windowStartMs: Long?,
        val checkedAtMs: Long?
    )

    /** Caller holds [mutex]. */
    private suspend fun clearImports() {
        if (store.importedHealthWorkouts.first().isNotEmpty()) {
            store.updateImportedHealthWorkouts { emptyList() }
        }
    }

    companion object {
        /** Matches iOS's Apple Health workout import window. */
        const val LOOKBACK_DAYS = 90L

        /** Sessions this recent are re-checked every sync: apps often finish writing a
         *  workout's calories after the session itself. */
        val CALORIE_RECHECK_WINDOW: Duration = Duration.ofDays(2)

        /** Older sessions are re-checked this often: another app can add or correct the
         *  calorie records without touching the session itself. */
        val CALORIE_REFRESH_INTERVAL: Duration = Duration.ofDays(7)

        /** Caps Health Connect aggregate calls per sync; the rest are looked up next time. */
        const val MAX_CALORIE_LOOKUPS_PER_SYNC = 60

        private val newestFirst = compareByDescending<ImportedHealthWorkout> { it.startedAt }.thenBy { it.id }
    }
}

/**
 * Whether [session]'s calories over [from, end) must be (re)read rather than reusing [stored]'s:
 * never resolved for this version of the session or this window, recent enough that its app may
 * still be writing them, or not checked within [ImportedHealthWorkoutRepository.CALORIE_REFRESH_INTERVAL].
 */
internal fun needsCalorieLookup(
    stored: ImportedHealthWorkout?,
    session: HealthExerciseSession,
    from: Instant,
    now: Instant
): Boolean {
    if (stored == null) return true
    if (stored.caloriesCheckedForModifiedMs != session.lastModified.toEpochMilli()) return true
    if (stored.caloriesWindowStartMs != from.toEpochMilli()) return true
    if (session.endTime.isAfter(now.minus(ImportedHealthWorkoutRepository.CALORIE_RECHECK_WINDOW))) return true
    val checkedAt = stored.caloriesCheckedAtEpochMs ?: return true
    return now.toEpochMilli() - checkedAt >= ImportedHealthWorkoutRepository.CALORIE_REFRESH_INTERVAL.toMillis()
}

/** Maps a Health Connect session to the stored model; null for a session without a positive duration. */
internal fun HealthExerciseSession.toImportedHealthWorkout(
    zone: ZoneId,
    sourceName: String?,
    activeCalories: Int?,
    caloriesCheckedForModifiedMs: Long?,
    caloriesWindowStartMs: Long? = null,
    caloriesCheckedAtEpochMs: Long? = null
): ImportedHealthWorkout? {
    val seconds = Duration.between(startTime, endTime).seconds
    if (seconds <= 0) return null
    return ImportedHealthWorkout(
        id = recordId,
        exerciseType = exerciseType,
        startedAt = startTime,
        endedAt = endTime,
        durationSeconds = seconds.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
        activeCalories = activeCalories?.takeIf { it > 0 },
        distanceMeters = lapDistanceMeters?.takeIf { it.isFinite() && it > 0.0 },
        sourcePackage = originPackage,
        sourceName = sourceName?.trim()?.takeIf { it.isNotEmpty() },
        deviceName = deviceName,
        diaryDateKey = startTime.atZone(zone).toLocalDate().toString(),
        lastModifiedEpochMs = lastModified.toEpochMilli(),
        caloriesCheckedForModifiedMs = caloriesCheckedForModifiedMs,
        caloriesWindowStartMs = caloriesWindowStartMs,
        caloriesCheckedAtEpochMs = caloriesCheckedAtEpochMs
    )
}

/**
 * Upserts [fetched] and drops stored sessions in the queried window that Health Connect no
 * longer returns (deleted in the source app). Older sessions outside the window are kept,
 * matching iOS ImportedHealthWorkoutStore.synchronize.
 */
internal fun reconcileImportedWorkouts(
    current: List<ImportedHealthWorkout>,
    fetched: List<ImportedHealthWorkout>,
    queryStart: Instant
): List<ImportedHealthWorkout> {
    val fetchedIds = fetched.mapTo(HashSet()) { it.id }
    val olderKept = current.filter { it.startedAt.isBefore(queryStart) && it.id !in fetchedIds }
    return (olderKept + fetched.distinctBy { it.id }).sortedByDescending { it.startedAt }
}
