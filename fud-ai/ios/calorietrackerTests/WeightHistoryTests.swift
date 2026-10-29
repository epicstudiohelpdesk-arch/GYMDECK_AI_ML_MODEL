import Foundation
import Testing
@testable import calorietracker

/// Weight history regressions: deleted readings coming back from Apple Health
/// (#518) and readings missing from the Progress chart (#519).
@MainActor
struct WeightHistoryTests {
    // MARK: - Deletion stays deleted

    @Test func deletedExternalHealthReadingIsNotImportedAgain() throws {
        try withStore { store, _ in
            let scale = WeightHealthSample(weightKg: 81.4, date: Date(timeIntervalSince1970: 1_790_000_000), fudaiID: nil)
            store.importHealthSamples([scale], restoreOwnSamplesIfEmpty: false)
            let imported = try #require(store.entries.first)

            store.deleteEntry(imported)
            #expect(store.entries.isEmpty)
            #expect(store.isDeletedHealthSample(scale))

            // The scale's sample is still in Apple Health; the next observer
            // fire or full-history import must not resurrect it.
            store.importHealthSamples([scale], restoreOwnSamplesIfEmpty: true)
            #expect(store.entries.isEmpty)

            // A genuinely new reading from the same source still imports.
            let nextDay = WeightHealthSample(weightKg: 81.0, date: scale.date.addingTimeInterval(86_400), fudaiID: nil)
            store.importHealthSamples([nextDay], restoreOwnSamplesIfEmpty: false)
            #expect(store.entries.map(\.weightKg) == [81.0])
        }
    }

    @Test func deletedReadingStaysDeletedWhenHealthHoldsItFromTwoSources() throws {
        try withStore { store, _ in
            // A scale and an app mirroring it both wrote the same weigh-in; the
            // import keeps one entry because they share the day and value.
            let morning = try #require(Calendar.current.date(
                bySettingHour: 8, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000)
            ))
            let scale = WeightHealthSample(weightKg: 80.0, date: morning, fudaiID: nil)
            let mirror = WeightHealthSample(weightKg: 80.0, date: scale.date.addingTimeInterval(600), fudaiID: nil)
            store.importHealthSamples([scale, mirror], restoreOwnSamplesIfEmpty: false)
            let imported = try #require(store.entries.first)
            #expect(store.entries.count == 1)

            store.deleteEntry(imported)

            // The observer now sees the mirror's sample as the latest reading.
            #expect(store.isDeletedHealthSample(mirror))
            store.importHealthSamples([scale, mirror], restoreOwnSamplesIfEmpty: true)
            #expect(store.entries.isEmpty)

            // A different value that day is a different weigh-in.
            let reweigh = WeightHealthSample(weightKg: 79.6, date: mirror.date.addingTimeInterval(600), fudaiID: nil)
            #expect(!store.isDeletedHealthSample(reweigh))
        }
    }

    @Test func deletionTombstoneMatchesOwnSamplesOnlyByIDOrExactReading() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let day = Date(timeIntervalSince1970: 1_790_000_000) // 14:13 UTC
        let tombstone = WeightDeletionTombstone(entryID: UUID(), date: day, weightKg: 72)

        // The same value re-logged in Fud AI later that day is a new entry.
        let relogged = WeightHealthSample(weightKg: 72, date: day.addingTimeInterval(1_800), fudaiID: UUID())
        #expect(!tombstone.matches(relogged, calendar: calendar))
        #expect(tombstone.matches(
            WeightHealthSample(weightKg: 72, date: day, fudaiID: UUID()), calendar: calendar
        ))
        #expect(tombstone.matches(
            WeightHealthSample(weightKg: 72, date: day.addingTimeInterval(1_800), fudaiID: nil), calendar: calendar
        ))
    }

    @Test func deletionTombstonesPersistAcrossLaunches() throws {
        try withStore { store, defaults in
            let entry = WeightEntry(date: Date(timeIntervalSince1970: 1_790_000_000), weightKg: 70)
            store.replaceAllEntries([entry])
            store.deleteEntry(entry)

            let relaunched = WeightStore(observesExternalChanges: false, defaults: defaults)
            #expect(relaunched.deletionTombstones == [
                WeightDeletionTombstone(entryID: entry.id, date: entry.date, weightKg: 70)
            ])
            #expect(relaunched.isDeletedHealthSample(
                WeightHealthSample(weightKg: 70, date: entry.date, fudaiID: nil)
            ))
        }
    }

    @Test func oldDeletionsStayRememberedAfterMoreThanAThousandDeletions() throws {
        try withStore { store, defaults in
            // A thousand earlier deletions, the first of a reading still in Apple Health.
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let first = WeightDeletionTombstone(entryID: UUID(), date: base, weightKg: 90)
            let later = (1..<1_000).map {
                WeightDeletionTombstone(entryID: UUID(), date: base.addingTimeInterval(Double($0) * 86_400), weightKg: 80)
            }
            defaults.set(try JSONEncoder().encode([first] + later), forKey: WeightStore.deletionTombstonesKey)

            let entry = WeightEntry(date: base.addingTimeInterval(86_400 * 1_200), weightKg: 75)
            store.replaceAllEntries([entry])
            store.deleteEntry(entry)

            #expect(store.deletionTombstones.count == 1_001)
            #expect(store.deletionTombstones.first == first)
            // A full-history import (new phone, types-version bump) must still skip it.
            store.importHealthSamples(
                [WeightHealthSample(weightKg: 90, date: base, fudaiID: nil)],
                restoreOwnSamplesIfEmpty: true
            )
            #expect(store.entries.isEmpty)
        }
    }

    @Test func healthImportReportsSamplesABlockedStoreCouldNotSave() throws {
        // HealthKitManager only advances its anchor (or stamps the backfill) when
        // the store reports the samples saved, so a blocked store gets them again.
        let sample = WeightHealthSample(weightKg: 81.4, date: Date(timeIntervalSince1970: 1_790_000_000), fudaiID: nil)
        let suite = "WeightHistoryTests.blocked.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("broken".utf8), forKey: WeightStore.storageKey)
        let blocked = WeightStore(
            observesExternalChanges: false,
            defaults: defaults,
            corruptBackupDirectory: URL(fileURLWithPath: "/dev/null/cannot-create")
        )

        #expect(blocked.isPersistenceBlocked)
        #expect(!blocked.importHealthSamples([sample], restoreOwnSamplesIfEmpty: false))
        #expect(!blocked.importHealthSamples([], restoreOwnSamplesIfEmpty: false))
        #expect(blocked.entries.isEmpty)

        try withStore { store, _ in
            #expect(store.importHealthSamples([sample], restoreOwnSamplesIfEmpty: false))
            // Nothing new (already logged) or nothing at all still counts as handled.
            #expect(store.importHealthSamples([sample], restoreOwnSamplesIfEmpty: false))
            #expect(store.importHealthSamples([], restoreOwnSamplesIfEmpty: false))
            #expect(store.entries.map(\.weightKg) == [81.4])
        }
    }

    @Test func deletedOwnSampleIsNotRestoredAfterReinstall() throws {
        try withStore { store, _ in
            let deleted = WeightEntry(date: Date(timeIntervalSince1970: 1_790_000_000), weightKg: 72)
            let kept = WeightEntry(date: Date(timeIntervalSince1970: 1_790_100_000), weightKg: 71)
            store.replaceAllEntries([deleted])
            // Our Health delete can fail (or lag); the tagged sample survives.
            store.deleteEntry(deleted)

            store.importHealthSamples([
                WeightHealthSample(weightKg: 72, date: deleted.date, fudaiID: deleted.id),
                WeightHealthSample(weightKg: 71, date: kept.date, fudaiID: kept.id),
            ], restoreOwnSamplesIfEmpty: true)

            #expect(store.entries.map(\.id) == [kept.id])
        }
    }

    @Test func healthImportDedupesAndOnlyRestoresOwnSamplesFromAnEmptyHistory() {
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let existing = [WeightEntry(date: day, weightKg: 80)]
        let samples = [
            WeightHealthSample(weightKg: 80.004, date: day.addingTimeInterval(60), fudaiID: nil), // same day + value
            WeightHealthSample(weightKg: 79.5, date: day.addingTimeInterval(-86_400 * 400), fudaiID: nil), // old backfill
            WeightHealthSample(weightKg: 79.5, date: day.addingTimeInterval(-86_400 * 400 + 30), fudaiID: nil), // batch dup
            WeightHealthSample(weightKg: 78, date: day.addingTimeInterval(86_400), fudaiID: UUID()), // own sample
        ]

        let fresh = WeightStore.healthImportCandidates(
            samples, existing: existing, tombstones: [], restoringOwnHistory: false
        )
        #expect(fresh.map(\.weightKg) == [79.5])

        let ownID = UUID()
        let restored = WeightStore.healthImportCandidates(
            [WeightHealthSample(weightKg: 78, date: day, fudaiID: ownID)],
            existing: [], tombstones: [], restoringOwnHistory: true
        )
        #expect(restored.map(\.id) == [ownID])
    }

    @Test func firstAnchoredWeightImportAfterACompletedBackfillOnlyFillsUnloggedDays() {
        // Existing installs already backfilled the full history; scanning it again
        // with the usual rules would re-add readings deleted before tombstones existed.
        #expect(HealthKitManager.weightChangesImport(hasAnchor: false, backfilledVersion: 9, typesVersion: 9) == .unloggedDaysOnly)
        #expect(HealthKitManager.weightChangesImport(hasAnchor: false, backfilledVersion: 0, typesVersion: 9) == .fullHistory)
        #expect(HealthKitManager.weightChangesImport(hasAnchor: false, backfilledVersion: 8, typesVersion: 9) == .fullHistory)
        #expect(HealthKitManager.weightChangesImport(hasAnchor: true, backfilledVersion: 9, typesVersion: 9) == .newSamples)
    }

    @Test func firstScanAfterTheBackfillImportsMissedReadingsButNotOldDeletions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let day = Date(timeIntervalSince1970: 1_790_000_000) // 14:13 UTC
        // The history after the old backfill: one weigh-in that day. Before this
        // update the user deleted a wrong scale reading from the same day, and no
        // tombstone recorded it.
        let existing = [WeightEntry(date: day, weightKg: 80)]
        let deletedBeforeUpdate = WeightHealthSample(weightKg: 92.3, date: day.addingTimeInterval(-3_600), fudaiID: nil)
        // Readings the latest-sample observer never saw: one backdated in Health,
        // two a scale synced late for the same day.
        let backdated = WeightHealthSample(weightKg: 84, date: day.addingTimeInterval(-86_400 * 60), fudaiID: nil)
        let lateFirst = WeightHealthSample(weightKg: 79.8, date: day.addingTimeInterval(86_400 * 2), fudaiID: nil)
        let lateSecond = WeightHealthSample(weightKg: 80.4, date: lateFirst.date.addingTimeInterval(3_600), fudaiID: nil)
        // Deleted since this build: its tombstone still applies.
        let tombstoned = WeightHealthSample(weightKg: 83, date: day.addingTimeInterval(-86_400 * 30), fudaiID: nil)
        let tombstone = WeightDeletionTombstone(entryID: UUID(), date: tombstoned.date, weightKg: 83)
        let own = WeightHealthSample(weightKg: 78, date: day.addingTimeInterval(86_400 * 3), fudaiID: UUID())
        let samples = [backdated, tombstoned, deletedBeforeUpdate, lateFirst, lateSecond, own]

        let fresh = WeightStore.healthImportCandidates(
            samples, existing: existing, tombstones: [tombstone],
            restoringOwnHistory: false, onlyUnloggedDays: true, calendar: calendar
        )
        #expect(fresh.map(\.weightKg) == [84, 79.8, 80.4])

        // The usual rules alone would bring the old deletion back.
        let usual = WeightStore.healthImportCandidates(
            samples, existing: existing, tombstones: [tombstone],
            restoringOwnHistory: false, calendar: calendar
        )
        #expect(usual.map(\.weightKg) == [84, 92.3, 79.8, 80.4])
    }

    @Test func storeImportsTheFirstAnchoredScanByItsMode() throws {
        try withStore { store, _ in
            let day = Date(timeIntervalSince1970: 1_790_000_000)
            store.replaceAllEntries([WeightEntry(date: day, weightKg: 80)])
            let sameDay = WeightHealthSample(weightKg: 92.3, date: day.addingTimeInterval(60), fudaiID: nil)
            let otherDay = WeightHealthSample(weightKg: 84, date: day.addingTimeInterval(-86_400 * 60), fudaiID: nil)

            #expect(store.importHealthSamples([sameDay, otherDay], for: .unloggedDaysOnly))
            #expect(store.entries.map(\.weightKg).sorted() == [80, 84])

            // Later runs (an anchor is stored) import new readings on logged days too.
            #expect(store.importHealthSamples([sameDay], for: .newSamples))
            #expect(store.entries.map(\.weightKg).sorted() == [80, 84, 92.3])
        }
    }

    // MARK: - Logging older weigh-ins

    @Test func backdatedWeighInNeverCountsAsReachingTheGoal() {
        let latest = WeightEntry(date: Date(timeIntervalSince1970: 1_790_000_000), weightKg: 80)
        let older = WeightEntry(date: latest.date.addingTimeInterval(-86_400 * 200), weightKg: 74)
        let newer = WeightEntry(date: latest.date.addingTimeInterval(86_400), weightKg: 74)

        #expect(!WeightStore.crossesGoal(older, previousLatest: latest, goalKg: 75, goal: .lose))
        #expect(WeightStore.crossesGoal(newer, previousLatest: latest, goalKg: 75, goal: .lose))
        #expect(!WeightStore.crossesGoal(
            WeightEntry(date: older.date, weightKg: 90), previousLatest: latest, goalKg: 85, goal: .gain
        ))
    }

    // MARK: - Chart range

    @Test func progressRangesIncludeReadingsLoggedToday() throws {
        try withStore { store, _ in
            let calendar = Calendar.current
            let today = Date()
            let threeDaysAgo = try #require(calendar.date(byAdding: .day, value: -3, to: today))
            let lastMonth = try #require(calendar.date(byAdding: .day, value: -30, to: today))
            store.replaceAllEntries([
                WeightEntry(date: lastMonth, weightKg: 82),
                WeightEntry(date: threeDaysAgo, weightKg: 81),
                WeightEntry(date: today, weightKg: 80),
            ])

            let week = store.entries(in: TimeRange.week.dayRange())
            #expect(week.map(\.weightKg) == [81, 80])
        }
    }

    @Test func allTimeRangeIncludesBackfilledOlderReadings() throws {
        try withStore { store, _ in
            let calendar = Calendar.current
            let today = Date()
            let twoYearsAgo = try #require(calendar.date(byAdding: .year, value: -2, to: today))
            store.replaceAllEntries([
                WeightEntry(date: today, weightKg: 80),
                WeightEntry(date: twoYearsAgo, weightKg: 95),
            ])

            let all = store.entries(in: TimeRange.allTime.dayRange())
            #expect(all.map(\.weightKg) == [95, 80])
        }
    }

    @Test func dayRangeContainsWholeLastDay() throws {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        let end = try #require(calendar.date(byAdding: .day, value: 6, to: start))
        let range = start...end
        let lateOnLastDay = try #require(calendar.date(byAdding: .hour, value: 23, to: end))
        let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: end))

        #expect(range.containsDay(of: start))
        #expect(range.containsDay(of: lateOnLastDay))
        #expect(!range.containsDay(of: nextDay))
        #expect(!range.containsDay(of: start.addingTimeInterval(-1)))
    }

    private func withStore(_ body: (WeightStore, UserDefaults) throws -> Void) throws {
        let suite = "WeightHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let backupDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeightHistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: backupDir)
        }
        let store = WeightStore(observesExternalChanges: false, defaults: defaults, corruptBackupDirectory: backupDir)
        try body(store, defaults)
    }
}
