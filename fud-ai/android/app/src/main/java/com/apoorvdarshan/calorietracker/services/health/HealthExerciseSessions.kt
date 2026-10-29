package com.apoorvdarshan.calorietracker.services.health

import androidx.health.connect.client.records.ExerciseSessionRecord
import java.time.Duration
import java.time.Instant
import kotlin.math.roundToInt

/** Application id shared by Fud AI's release build and its `.debug` / `.debug2` variants. */
internal const val FUD_AI_APPLICATION_ID = "com.apoorvdarshan.calorietracker"

/** Every package name a Fud AI build writes Health Connect records under. */
internal val FUD_AI_HEALTH_PACKAGES: Set<String> = setOf(
    FUD_AI_APPLICATION_ID,
    "$FUD_AI_APPLICATION_ID.debug",
    "$FUD_AI_APPLICATION_ID.debug2"
)

/** True for records any Fud AI build wrote, so they are never imported back as another app's data. */
internal fun isFudAiHealthOrigin(packageName: String, ownPackage: String = FUD_AI_APPLICATION_ID): Boolean =
    packageName == ownPackage ||
        packageName == FUD_AI_APPLICATION_ID ||
        packageName.startsWith("$FUD_AI_APPLICATION_ID.")

/** The fields of an ExerciseSessionRecord the workout import keeps, read from Health Connect. */
data class HealthExerciseSession(
    val recordId: String,
    val exerciseType: Int,
    val startTime: Instant,
    val endTime: Instant,
    val originPackage: String,
    val lastModified: Instant,
    val deviceName: String?,
    /** Sum of the session's lap lengths in meters; null when it has none. */
    val lapDistanceMeters: Double?
)

/**
 * Another app's session, or null for one written by Fud AI itself (any build) and for
 * malformed rows (no record id, or a session that does not end after it starts).
 */
internal fun ExerciseSessionRecord.toExternalHealthExerciseSession(
    ownPackage: String = FUD_AI_APPLICATION_ID
): HealthExerciseSession? {
    val origin = metadata.dataOrigin.packageName
    if (origin.isBlank() || isFudAiHealthOrigin(origin, ownPackage)) return null
    val id = metadata.id.takeIf { it.isNotBlank() } ?: return null
    if (!endTime.isAfter(startTime)) return null
    val lapMeters = laps.mapNotNull { lap ->
        lap.length?.inMeters?.takeIf { it.isFinite() && it > 0.0 }
    }
    return HealthExerciseSession(
        recordId = id,
        exerciseType = exerciseType,
        startTime = startTime,
        endTime = endTime,
        originPackage = origin,
        lastModified = metadata.lastModifiedTime,
        deviceName = healthDeviceName(metadata.device?.manufacturer, metadata.device?.model),
        lapDistanceMeters = lapMeters.takeIf { it.isNotEmpty() }?.sum()
    )
}

/** Share of the longer session two sessions must have in common to be one workout recorded twice. */
internal const val DUPLICATE_SESSION_SHARED_FRACTION = 0.8

/**
 * Whether [a] and [b] are one workout recorded twice, typically by the watch's app and an app
 * that copies from it (Garmin Connect and Strava): they share at least
 * [DUPLICATE_SESSION_SHARED_FRACTION] of the longer session's time. One person cannot do two
 * workouts at once, so the recording app and exercise type do not matter.
 */
internal fun isSameWorkout(a: HealthExerciseSession, b: HealthExerciseSession): Boolean {
    val shared = Duration.between(maxOf(a.startTime, b.startTime), minOf(a.endTime, b.endTime)).toMillis()
    if (shared <= 0) return false
    val longer = maxOf(
        Duration.between(a.startTime, a.endTime).toMillis(),
        Duration.between(b.startTime, b.endTime).toMillis()
    )
    return shared >= DUPLICATE_SESSION_SHARED_FRACTION * longer
}

/**
 * [sessions] with one session per workout, in their original order. Of the copies of one
 * workout ([isSameWorkout]), one already imported ([importedIds]) stays, so the row does not
 * switch apps when a copy is edited; otherwise the first one written wins (the recording app,
 * ahead of apps that copy from it).
 */
internal fun withoutDuplicateSessions(
    sessions: List<HealthExerciseSession>,
    importedIds: Set<String>
): List<HealthExerciseSession> {
    val kept = ArrayList<HealthExerciseSession>()
    sessions.sortedWith(
        compareByDescending<HealthExerciseSession> { it.recordId in importedIds }
            .thenBy { it.lastModified }
            .thenBy { it.recordId }
    ).forEach { candidate ->
        if (kept.none { isSameWorkout(it, candidate) }) kept += candidate
    }
    val keptIds = kept.mapTo(HashSet()) { it.recordId }
    return sessions.filter { it.recordId in keptIds }
}

/** Earliest first, the longer first on a shared start: the order earlier sessions claim shared time in. */
internal val calorieWindowOrder: Comparator<HealthExerciseSession> =
    compareBy<HealthExerciseSession> { it.startTime }
        .thenByDescending { it.endTime }
        .thenBy { it.recordId }

/**
 * Where each session's calorie window starts (by record id), so sessions that still overlap
 * never count the same time twice: the session's own start, or the latest end among sessions
 * that started before it, whichever is later. A session that lies wholly inside earlier ones
 * gets its own end: an empty window, so no calories of its own.
 */
internal fun calorieWindowStarts(sessions: List<HealthExerciseSession>): Map<String, Instant> {
    val starts = HashMap<String, Instant>()
    var coveredUntil: Instant? = null
    for (session in sessions.sortedWith(calorieWindowOrder)) {
        val covered = coveredUntil
        starts[session.recordId] = if (covered != null && covered.isAfter(session.startTime)) {
            minOf(covered, session.endTime)
        } else {
            session.startTime
        }
        if (covered == null || session.endTime.isAfter(covered)) coveredUntil = session.endTime
    }
    return starts
}

/** "Garmin Forerunner 265" from manufacturer + model, without repeating a manufacturer the model already names. */
internal fun healthDeviceName(manufacturer: String?, model: String?): String? {
    val maker = manufacturer?.trim()?.takeIf { it.isNotEmpty() }
    val name = model?.trim()?.takeIf { it.isNotEmpty() }
    return when {
        maker == null -> name
        name == null -> maker
        name.startsWith(maker, ignoreCase = true) -> name
        else -> "$maker $name"
    }
}

/**
 * Active calories to show for an imported session, in kcal. The recording app's own
 * Active Calories Burned over the session wins. Otherwise the session window's active
 * energy from every app except Fud AI ([allWindowKcal] minus [ownWindowKcal]) is used,
 * so a calculated burn Fud AI wrote into the same window is never counted. Null when
 * nothing positive remains.
 */
internal fun attributedSessionActiveCalories(
    sameOriginKcal: Double?,
    allWindowKcal: Double?,
    ownWindowKcal: Double?
): Int? {
    sameOriginKcal?.takeIf { it.isFinite() && it > 0.0 }?.let { kcal ->
        return kcal.roundToInt().takeIf { it > 0 }
    }
    val all = allWindowKcal?.takeIf { it.isFinite() } ?: return null
    val own = ownWindowKcal?.takeIf { it.isFinite() } ?: 0.0
    return externalActiveCalories(all, own).roundToInt().takeIf { it > 0 }
}

/** Outcome of one session's calorie lookup. [Failed] keeps the stored value and retries later. */
sealed interface SessionCalorieLookup {
    data class Resolved(val activeCalories: Int?) : SessionCalorieLookup
    data object Failed : SessionCalorieLookup
}
