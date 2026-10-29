import Foundation
import SwiftUI

@Observable
class WeightStore {
    private(set) var entries: [WeightEntry] = []
    var onEntryAdded: ((WeightEntry) -> Void)?
    var onEntryDeleted: ((UUID) -> Void)?

    static let storageKey = "weightEntries"
    /// Not prefixed `healthKit`, so iCloud backups carry it: a restore onto a
    /// new phone re-runs the Apple Health import and must still skip deletions.
    /// Never trimmed: each tombstone is one deletion the user made by hand
    /// (well under 100 bytes), and dropping one lets its reading come back.
    static let deletionTombstonesKey = "weightDeletionTombstones"
    private let observesExternalChanges: Bool
    private let defaults: UserDefaults
    private let entriesBlob: PersistedBlobGuard

    /// True while an unreadable weight blob is on disk without a backup copy;
    /// mutations are refused so they cannot overwrite the user's history.
    var isPersistenceBlocked: Bool { entriesBlob.isWriteBlocked }
    var corruptBlobBackups: [PersistedBlobGuard.CorruptBackup] { entriesBlob.backups }

    static let externalChangeNotification = "ai.fud.weightEntriesDidChange"

    init(
        observesExternalChanges: Bool = true,
        defaults: UserDefaults = .standard,
        corruptBackupDirectory: URL? = nil
    ) {
        self.observesExternalChanges = observesExternalChanges
        self.defaults = defaults
        self.entriesBlob = PersistedBlobGuard(defaults: defaults, key: Self.storageKey, backupDirectory: corruptBackupDirectory)
        loadEntries(isInitialLoad: true)
        if observesExternalChanges {
            startObservingExternalChanges()
        }
        // No default seed — WeightStore.init runs before onboarding finishes on a fresh
        // install, so `UserProfile.load()` is nil and the old seed fell back to .default
        // (70 kg), dropping a phantom 70 kg entry onto every new user's chart even if
        // their real weight was different. Onboarding now seeds the first WeightEntry
        // via `seedInitialWeightFromProfileIfEmpty(_:)` once the profile is real.
    }

    deinit {
        guard observesExternalChanges else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            CFNotificationName(Self.externalChangeNotification as CFString),
            nil
        )
    }

    /// Add the first WeightEntry from the user's onboarding-set profile weight.
    /// Safe to call multiple times — no-op if any entries already exist, so subsequent
    /// scene-active firings or re-onboarding paths can't duplicate.
    func seedInitialWeightFromProfileIfEmpty(_ weightKg: Double) {
        guard entries.isEmpty else { return }
        addEntry(WeightEntry(date: .now, weightKg: weightKg))
    }

    var latestEntry: WeightEntry? {
        entries.sorted { $0.date > $1.date }.first
    }

    /// Entries logged on any calendar day `range` covers. `TimeRange.dayRange()`
    /// bounds are day starts, so a plain `contains` dropped today's readings.
    func entries(in range: ClosedRange<Date>) -> [WeightEntry] {
        entries
            .filter { range.containsDay(of: $0.date) }
            .sorted { $0.date < $1.date }
    }

    func addEntry(_ entry: WeightEntry) {
        guard !isPersistenceBlocked else { return }
        let previousLatest = entries.sorted { $0.date > $1.date }.first
        entries.append(entry)
        saveEntries()
        onEntryAdded?(entry)

        syncProfileWeightToLatest()

        // Detect goal-weight crossing — fire only on the transition, not on every weight past goal.
        if let profile = UserProfile.load(), let goalKg = profile.goalWeightKg, let previous = previousLatest,
           Self.crossesGoal(entry, previousLatest: previous, goalKg: goalKg, goal: profile.goal) {
            NotificationCenter.default.post(name: .weightGoalReached, object: nil)
        }
    }

    /// Only a new latest reading can reach the goal: a weigh-in logged for an
    /// earlier day is history, not progress.
    static func crossesGoal(_ entry: WeightEntry, previousLatest previous: WeightEntry, goalKg: Double, goal: WeightGoal) -> Bool {
        guard entry.date >= previous.date else { return false }
        switch goal {
        case .lose:    return previous.weightKg > goalKg && entry.weightKg <= goalKg
        case .gain:    return previous.weightKg < goalKg && entry.weightKg >= goalKg
        case .maintain: return false
        }
    }

    func deleteEntry(_ entry: WeightEntry) {
        guard !isPersistenceBlocked else { return }
        let id = entry.id
        let removed = entries.filter { $0.id == id }
        entries.removeAll { $0.id == id }
        saveEntries()
        rememberDeletion(of: removed.isEmpty ? [entry] : removed)
        onEntryDeleted?(id)
        syncProfileWeightToLatest()
    }

    // MARK: - Deletion tombstones

    /// Deleting only removes Fud AI's own Health sample. Readings from other
    /// sources stay in Apple Health, so without this the Health observer (and
    /// the full-history imports) put a deleted weight straight back.
    var deletionTombstones: [WeightDeletionTombstone] {
        guard let data = defaults.data(forKey: Self.deletionTombstonesKey) else { return [] }
        return (try? JSONDecoder().decode([WeightDeletionTombstone].self, from: data)) ?? []
    }

    func isDeletedHealthSample(_ sample: WeightHealthSample) -> Bool {
        deletionTombstones.contains { $0.matches(sample) }
    }

    private func rememberDeletion(of deleted: [WeightEntry]) {
        var tombstones = deletionTombstones
        tombstones.append(contentsOf: deleted.map {
            WeightDeletionTombstone(entryID: $0.id, date: $0.date, weightKg: $0.weightKg)
        })
        guard let data = try? JSONEncoder().encode(tombstones) else { return }
        defaults.set(data, forKey: Self.deletionTombstonesKey)
    }

    /// Keep UserProfile.weightKg aligned with the most recent weight entry so Settings (Weight row)
    /// and Progress (Current badge) never disagree. If the store is empty, leave the profile as-is
    /// — we still need some weightKg for BMR/TDEE math; user can log a new one.
    private func syncProfileWeightToLatest() {
        guard var profile = UserProfile.load(),
              let newest = entries.sorted(by: { $0.date > $1.date }).first else { return }
        if abs(profile.weightKg - newest.weightKg) > 0.01 {
            profile.weightKg = newest.weightKg
            profile.save()
        }
    }

    func reloadFromDefaults() {
        loadEntries(isInitialLoad: false)
    }

    func replaceAllEntries(_ newEntries: [WeightEntry]) {
        guard !isPersistenceBlocked else { return }
        entries = newEntries
        saveEntries()
    }

    /// Bulk-import weight samples discovered from HealthKit (e.g. years of
    /// scale history that predate Fud AI). Bypasses onEntryAdded so the
    /// imported externals don't echo back to HK as fresh writes — these
    /// samples already exist there. Saves + syncs profile once at the end.
    /// Samples whose id is already in the store (a restore that raced a
    /// live observer write, or the same batch delivered twice) are skipped so
    /// the list never accumulates duplicate ids. Returns false when the batch
    /// could not be saved (persistence blocked, or the save failed and was
    /// rolled back), so a caller tracking its progress can retry it.
    @discardableResult
    func importExternalEntries(_ external: [WeightEntry]) -> Bool {
        guard !isPersistenceBlocked else { return false }
        var seen = Set(entries.map(\.id))
        let fresh = external.filter { seen.insert($0.id).inserted }
        guard !fresh.isEmpty else { return true }
        entries.append(contentsOf: fresh)
        guard saveEntries() else {
            entries.removeLast(fresh.count)
            return false
        }
        syncProfileWeightToLatest()
        return true
    }

    /// Imports Apple Health readings. Skips readings already in the history
    /// (same day, same value), readings the user deleted here, and Fud AI's own
    /// samples unless the history is empty (reinstall / new phone restore).
    /// Decided against the live entries so overlapping imports can't duplicate.
    /// Returns false when the samples were not saved; HealthKitManager then
    /// keeps its import anchor (or backfill version) so they arrive again.
    /// `onlyUnloggedDays` also skips readings on any day the history already
    /// has a weigh-in for (see `HealthKitManager.WeightChangesImport`).
    @discardableResult
    /// `addingMissingOwnSamples` also brings back Fud AI's own readings into a
    /// history that isn't empty (after a welcome-back restore), skipping ids it holds.
    func importHealthSamples(
        _ samples: [WeightHealthSample],
        restoreOwnSamplesIfEmpty: Bool,
        onlyUnloggedDays: Bool = false,
        addingMissingOwnSamples: Bool = false
    ) -> Bool {
        guard !isPersistenceBlocked else { return false }
        guard !samples.isEmpty else { return true }
        return importExternalEntries(Self.healthImportCandidates(
            samples,
            existing: entries,
            tombstones: deletionTombstones,
            restoringOwnHistory: (restoreOwnSamplesIfEmpty && entries.isEmpty) || addingMissingOwnSamples,
            onlyUnloggedDays: onlyUnloggedDays
        ))
    }

    /// One run of HealthKitManager's anchored weight import.
    @discardableResult
    func importHealthSamples(_ samples: [WeightHealthSample], for mode: HealthKitManager.WeightChangesImport) -> Bool {
        importHealthSamples(
            samples,
            restoreOwnSamplesIfEmpty: mode == .fullHistory,
            onlyUnloggedDays: mode == .unloggedDaysOnly
        )
    }

    static func healthImportCandidates(
        _ samples: [WeightHealthSample],
        existing: [WeightEntry],
        tombstones: [WeightDeletionTombstone],
        restoringOwnHistory: Bool,
        onlyUnloggedDays: Bool = false,
        calendar: Calendar = .current
    ) -> [WeightEntry] {
        // Same-day + close-value match catches our own pre-metadata writes,
        // externals already imported, and same-day duplicates within this
        // batch (an entry write + a profile push on the same day).
        var loggedByDay: [Date: [Double]] = [:]
        for entry in existing {
            loggedByDay[calendar.startOfDay(for: entry.date), default: []].append(entry.weightKg)
        }
        // Days the history held before this batch; readings from the batch
        // itself don't close a day to its other readings.
        let historyDays = Set(loggedByDay.keys)
        let existingIDs = Set(existing.map(\.id))
        var fresh: [WeightEntry] = []
        for sample in samples {
            let day = calendar.startOfDay(for: sample.date)
            if onlyUnloggedDays && historyDays.contains(day) { continue }
            if loggedByDay[day, default: []].contains(where: { abs($0 - sample.weightKg) < 0.01 }) { continue }
            if tombstones.contains(where: { $0.matches(sample, calendar: calendar) }) { continue }
            if let fudaiID = sample.fudaiID {
                // Own samples are either already represented or synthetic
                // profile pushes (writeWeight(kg:date:)) that never had an entry.
                guard restoringOwnHistory, !existingIDs.contains(fudaiID) else { continue }
                // Keep the ORIGINAL entry id so a later in-app delete of the
                // restored entry still finds its HK sample by metadata.
                fresh.append(WeightEntry(id: fudaiID, date: sample.date, weightKg: sample.weightKg))
            } else {
                fresh.append(WeightEntry(date: sample.date, weightKg: sample.weightKg))
            }
            loggedByDay[day, default: []].append(sample.weightKg)
        }
        return fresh
    }

    /// Upserts by id; duplicate ids resolve newest-wins instead of trapping.
    func mergeWithCloudEntries(_ cloudEntries: [WeightEntry]) {
        guard !isPersistenceBlocked else { return }
        entries = Self.mergingByID(entries, with: cloudEntries)
        saveEntries()
    }

    static func mergingByID(_ existing: [WeightEntry], with incoming: [WeightEntry]) -> [WeightEntry] {
        var order: [UUID] = []
        var byID: [UUID: WeightEntry] = [:]
        for entry in existing + incoming {
            if byID.updateValue(entry, forKey: entry.id) == nil {
                order.append(entry.id)
            }
        }
        return order.compactMap { byID[$0] }
    }

    @discardableResult
    private func saveEntries() -> Bool {
        entriesBlob.save(entries)
    }

    private func loadEntries(isInitialLoad: Bool) {
        switch entriesBlob.loadList(WeightEntry.self) {
        case .missing:
            entries = []
        case .decoded(let decoded, _):
            entries = decoded
        case .corrupt:
            // Backed up (or write-blocked until it is). Keep the in-memory
            // copy on reloads instead of presenting an empty history.
            if isInitialLoad { entries = [] }
        }
    }

    private func startObservingExternalChanges() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let store = Unmanaged<WeightStore>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    store.reloadFromExternalChange()
                }
            },
            Self.externalChangeNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func reloadFromExternalChange() {
        loadEntries(isInitialLoad: false)
        syncProfileWeightToLatest()
    }

    static func postExternalChangeNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(externalChangeNotification as CFString),
            nil,
            nil,
            true
        )
    }
}
