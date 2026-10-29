package com.apoorvdarshan.calorietracker.data

import com.apoorvdarshan.calorietracker.models.WeightEntry
import com.apoorvdarshan.calorietracker.models.WeightGoal
import com.apoorvdarshan.calorietracker.services.health.ExternalWeight
import com.apoorvdarshan.calorietracker.services.health.HealthConnectManager
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import java.time.Instant
import java.util.UUID
import kotlin.math.abs

/** Emitted when the user crosses their goal weight (under -> at/below for lose, over -> at/above for gain). */
data class WeightGoalReachedEvent(val reachedEntry: WeightEntry)

/**
 * CRUD + reactive reads for weight entries. Port of iOS WeightStore.
 * Also handles two cross-cutting behaviors:
 *
 * 1. After each add/delete, syncs [UserProfile.weightKg] to the latest entry
 *    so BMR/TDEE math and Settings stay in sync with Progress.
 * 2. Returns a [WeightGoalReachedEvent] from [addEntry] when the new weight
 *    crosses the user's goal, for the caller to surface as a celebration UI.
 */
class WeightRepository(
    private val prefs: PreferencesStore,
    private val profileRepository: ProfileRepository,
    private val health: HealthConnectManager? = null
) {
    val entries: Flow<List<WeightEntry>> = prefs.weightEntries.map { it.sortedBy { e -> e.date } }

    val latest: Flow<WeightEntry?> = prefs.weightEntries.map { list ->
        list.maxByOrNull { it.date }
    }

    /** Safe to call repeatedly — no-ops once any entries exist. */
    suspend fun seedInitialWeightIfEmpty(weightKg: Double) {
        if (prefs.weightEntries.first().isNotEmpty()) return
        addEntry(WeightEntry(weightKg = weightKg))
    }

    suspend fun addEntry(entry: WeightEntry): WeightGoalReachedEvent? {
        var latestBeforeAdd: WeightEntry? = null
        prefs.updateWeightEntries { current ->
            latestBeforeAdd = current.maxByOrNull { it.date }
            current + entry
        }
        val previousLatest = latestBeforeAdd

        syncProfileWeightToLatest()
        if (shouldSyncHealth()) {
            health?.writeWeight(entry)
        }

        val profile = profileRepository.current()
        val goal = profile?.goalWeightKg
        if (profile != null && goal != null && previousLatest != null &&
            crossesWeightGoal(entry, previousLatest, goal, profile.goal)
        ) {
            return WeightGoalReachedEvent(entry)
        }
        return null
    }

    suspend fun deleteEntry(id: UUID) {
        // Remember the deletion first: a Health Connect re-import (expired changes token,
        // cloud restore, newly granted history) would otherwise bring back a weigh-in
        // another app wrote, since only our own record is deleted below.
        prefs.addDeletedWeightEntryId(id.toString())
        prefs.updateWeightEntries { current -> current.filter { it.id != id } }
        syncProfileWeightToLatest()
        // Delete the HC record even when sync is off (iOS parity, best-effort) —
        // a surviving fudai-tagged record would resurrect through the own-record
        // restore path on the next full backfill.
        health?.deleteWeight(id)
    }

    suspend fun replaceAll(entries: List<WeightEntry>) {
        prefs.setWeightEntries(entries)
        syncProfileWeightToLatest()
    }

    suspend fun clear() {
        prefs.setWeightEntries(emptyList())
    }

    suspend fun entriesInRange(from: Instant, to: Instant): List<WeightEntry> =
        prefs.weightEntries.first()
            .filter { it.date in from..to }
            .sortedBy { it.date }

    private suspend fun syncProfileWeightToLatest() {
        val profile = profileRepository.current() ?: return
        val newest = prefs.weightEntries.first().maxByOrNull { it.date } ?: return
        if (abs(profile.weightKg - newest.weightKg) > 0.01) {
            profileRepository.save(profile.copy(weightKg = newest.weightKg))
        }
    }

    /**
     * Merge externally-sourced weigh-ins (e.g. a Withings scale via Health Connect)
     * into local history. Idempotent: each external record maps to a deterministic id
     * so repeated imports upsert in place instead of duplicating, and the user's own
     * manual entries (random ids) are preserved. Records Fud AI itself wrote restore
     * under their original UUID — after a reinstall the local store is empty and this
     * is what brings the history back; when the entry still exists locally the
     * same-id upsert is a no-op. The change-token path filters own records at the
     * manager level, so live echo-imports are still suppressed. Ids the user deleted
     * are skipped, so a re-import can't bring them back.
     */
    suspend fun importExternalWeights(external: List<ExternalWeight>) {
        val manager = health ?: return
        val incoming = toEntries(manager, external)
        if (incoming.isEmpty()) return
        var changed = false
        // Deleted ids are read inside the merge's transaction: a snapshot taken before it
        // could miss a deletion that lands in between and add the reading back.
        prefs.updateWeightEntriesSkippingDeleted { current, deletedIds ->
            val merged = mergeExternalWeights(current, incoming, deletedIds)
            changed = merged != null
            merged ?: current
        }
        if (!changed) return
        syncProfileWeightToLatest()
    }

    /**
     * After a Drive restore: adds only the weigh-ins the restored history lacks, under the
     * same ids [importExternalWeights] gives them. Ids it already holds are left exactly as
     * restored, deleted ids stay deleted, and the profile is not touched.
     */
    suspend fun addMissingExternalWeights(external: List<ExternalWeight>) {
        val manager = health ?: return
        val incoming = toEntries(manager, external)
        if (incoming.isEmpty()) return
        prefs.updateWeightEntriesSkippingDeleted { current, deletedIds ->
            addMissingById(current, incoming, deletedIds, WeightEntry::id)?.sortedBy { it.date } ?: current
        }
    }

    private fun toEntries(manager: HealthConnectManager, external: List<ExternalWeight>): List<WeightEntry> =
        external.map {
            WeightEntry(
                id = manager.ownRecordId(it.clientRecordId)
                    ?: externalId(it.clientRecordId, it.recordId, it.time),
                date = it.time,
                weightKg = it.weightKg
            )
        }

    /** Times of the readings in [external] that another app wrote and the history already
     *  holds, matched by the id [importExternalWeights] gives them. */
    suspend fun heldExternalReadingTimes(external: List<ExternalWeight>): List<Instant> {
        val manager = health ?: return emptyList()
        val held = prefs.weightEntries.first().mapTo(HashSet()) { it.id }
        return external
            .filter { !manager.isOwnRecord(it.clientRecordId) && externalId(it.clientRecordId, it.recordId, it.time) in held }
            .map { it.time }
    }

    /** Stable id for an external record: prefer the source's clientRecordId, then the
     *  Health Connect record id, then the timestamp. Crucially the VALUE is never part of
     *  the seed, so an in-place correction (same record, new weight) upserts in place
     *  instead of leaving an orphaned duplicate. */
    private fun externalId(clientRecordId: String?, recordId: String, time: Instant): UUID {
        val seed = clientRecordId?.takeIf { it.isNotBlank() }
            ?: recordId.takeIf { it.isNotBlank() }
            ?: "hc-weight:${time.toEpochMilli()}"
        return UUID.nameUUIDFromBytes(seed.toByteArray())
    }

    /** Write gate — only push to Health Connect when the user granted weight WRITE. */
    private suspend fun shouldSyncHealth(): Boolean {
        val manager = health ?: return false
        return prefs.healthConnectEnabled.first() && manager.hasWeightWrite()
    }
}

/** Only a new latest reading can reach the goal: a weigh-in logged for an earlier day is
 *  history, not progress. */
internal fun crossesWeightGoal(
    entry: WeightEntry,
    previousLatest: WeightEntry,
    goalKg: Double,
    goal: WeightGoal
): Boolean {
    if (entry.date < previousLatest.date) return false
    return when (goal) {
        WeightGoal.LOSE -> previousLatest.weightKg > goalKg && entry.weightKg <= goalKg
        WeightGoal.GAIN -> previousLatest.weightKg < goalKg && entry.weightKg >= goalKg
        WeightGoal.MAINTAIN -> false
    }
}

/**
 * [current] plus the [incoming] records whose id it doesn't hold yet, skipping ids in
 * [deletedIds] and repeats within [incoming]. Existing records are never replaced. Null
 * when nothing is added.
 */
internal fun <T> addMissingById(
    current: List<T>,
    incoming: List<T>,
    deletedIds: Set<String>,
    id: (T) -> UUID
): List<T>? {
    val held = current.mapTo(HashSet()) { id(it) }
    val added = incoming.filter { id(it).toString() !in deletedIds && held.add(id(it)) }
    return if (added.isEmpty()) null else current + added
}

/**
 * Upserts Health Connect weigh-ins into [current] by id, skipping ids in [deletedIds].
 * Returns the merged history sorted by date, or null when nothing changed.
 */
internal fun mergeExternalWeights(
    current: List<WeightEntry>,
    incoming: List<WeightEntry>,
    deletedIds: Set<String>
): List<WeightEntry>? {
    // associateBy keeps the last duplicate id, so a history that already
    // holds the same id twice collapses instead of failing the import.
    val byId = current.associateBy { it.id }.toMutableMap()
    // Persist the collapse even if every incoming value already matches,
    // otherwise the duplicate survives and keeps skewing the trend math.
    var changed = byId.size != current.size
    for (entry in incoming) {
        if (entry.id.toString() in deletedIds) continue
        val existing = byId[entry.id]
        if (existing == null || abs(existing.weightKg - entry.weightKg) > 0.0001 || existing.date != entry.date) {
            byId[entry.id] = entry
            changed = true
        }
    }
    return if (changed) byId.values.sortedBy { it.date } else null
}
