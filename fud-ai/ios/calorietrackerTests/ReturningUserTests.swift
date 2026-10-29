import CloudKit
import Foundation
import HealthKit
import Testing
@testable import calorietracker

/// The welcome-back screen's pure logic: when it opens, how Health values land
/// on the onboarding wheels, the import summary, and the iCloud presence check.
@MainActor
struct ReturningUserTests {
    // MARK: - Opening the screen

    @Test func savedAPIKeyOpensWelcomeBack() {
        #expect(ReturningUser.opensWelcomeBack(isRunningTests: false, forcedByTest: false, hasSavedAPIKey: { true }))
        #expect(!ReturningUser.opensWelcomeBack(isRunningTests: false, forcedByTest: false, hasSavedAPIKey: { false }))
    }

    @Test func testLaunchesOnlyOpenItWhenAskedAndNeverReadTheKeychain() {
        var readKeychain = false
        #expect(!ReturningUser.opensWelcomeBack(isRunningTests: true, forcedByTest: false, hasSavedAPIKey: {
            readKeychain = true
            return true
        }))
        #expect(ReturningUser.opensWelcomeBack(isRunningTests: true, forcedByTest: true, hasSavedAPIKey: {
            readKeychain = true
            return false
        }))
        #expect(!readKeychain)
    }

    // MARK: - Wizard wheels

    @Test func heightFillsBothWheelLayouts() {
        #expect(ReturningUser.heightWheels(cm: 175.3) == .init(cm: 175, feet: 5, inches: 9))
        #expect(ReturningUser.heightWheels(cm: 182.88) == .init(cm: 183, feet: 6, inches: 0))
    }

    @Test func heightIsClampedToTheWheels() {
        #expect(ReturningUser.heightWheels(cm: 50) == .init(cm: 100, feet: 3, inches: 0))
        #expect(ReturningUser.heightWheels(cm: 300) == .init(cm: 250, feet: 8, inches: 11))
        #expect(ReturningUser.heightWheels(cm: 0) == nil)
        #expect(ReturningUser.heightWheels(cm: .nan) == nil)
        #expect(ReturningUser.heightWheels(cm: .infinity) == nil)
    }

    @Test func weightFillsBothUnits() {
        #expect(ReturningUser.weightWheels(kg: 72.3) == .init(kgWhole: 72, kgTenth: 3, lbsWhole: 159, lbsTenth: 4))
    }

    @Test func weightIsClampedToTheWheels() {
        #expect(ReturningUser.weightWheels(kg: 10) == .init(kgWhole: 30, kgTenth: 0, lbsWhole: 60, lbsTenth: 0))
        #expect(ReturningUser.weightWheels(kg: 400) == .init(kgWhole: 250, kgTenth: 9, lbsWhole: 500, lbsTenth: 9))
        #expect(ReturningUser.weightWheels(kg: -1) == nil)
        #expect(ReturningUser.weightWheels(kg: .nan) == nil)
    }

    @Test func bodyFatBecomesAWholePercentOnTheWheel() {
        #expect(ReturningUser.bodyFatWheel(fraction: 0.184) == 18)
        #expect(ReturningUser.bodyFatWheel(fraction: 0.01) == 3)
        #expect(ReturningUser.bodyFatWheel(fraction: 0.9) == 60)
        #expect(ReturningUser.bodyFatWheel(fraction: 0) == nil)
        #expect(ReturningUser.bodyFatWheel(fraction: .nan) == nil)
    }

    @Test func birthdayNeverLandsInTheFuture() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ReturningUser.birthdayWheel(now.addingTimeInterval(86_400), now: now) == now)
        let past = now.addingTimeInterval(-30 * 365 * 86_400)
        #expect(ReturningUser.birthdayWheel(past, now: now) == past)
    }

    @Test func onlyMaleAndFemaleMapToTheWizard() {
        #expect(ReturningUser.gender(for: .male) == .male)
        #expect(ReturningUser.gender(for: .female) == .female)
        #expect(ReturningUser.gender(for: .other) == nil)
        #expect(ReturningUser.gender(for: .notSet) == nil)
        #expect(ReturningUser.gender(for: nil) == nil)
    }

    // MARK: - Import summary

    @Test func importCountsOnlyWhatWasAdded() {
        let before = ReturningUser.HealthImportCounts(meals: 2, weighIns: 0, bodyFatReadings: 1, workouts: 4)
        let after = ReturningUser.HealthImportCounts(meals: 122, weighIns: 45, bodyFatReadings: 1, workouts: 3)
        #expect(ReturningUser.HealthImportCounts.added(from: before, to: after)
                == .init(meals: 120, weighIns: 45, bodyFatReadings: 0, workouts: 0))
    }

    @Test func emptyImportHasNoSummary() {
        #expect(ReturningUser.importSummary(.init()) == nil)
    }

    @Test(.enabled(if: Bundle.main.preferredLocalizations.first == "en"))
    func importSummaryListsWhatCameBack() {
        let english = Locale(identifier: "en_US")
        #expect(ReturningUser.importSummary(.init(meals: 120, weighIns: 45), locale: english)
                == "Imported 120 meals and 45 weigh-ins.")
        #expect(ReturningUser.importSummary(.init(meals: 1, workouts: 1), locale: english)
                == "Imported 1 meal and calories for 1 workout.")
        #expect(ReturningUser.importSummary(.init(meals: 3, weighIns: 2, bodyFatReadings: 1, workouts: 5), locale: english)
                == "Imported 3 meals, 2 weigh-ins, 1 body-fat reading, and calories for 5 workouts.")
    }

    // MARK: - iCloud presence check

    @Test func probeFindsTheBackupRecord() {
        let record = CKRecord(recordType: "FudAIBackup", recordID: CKRecord.ID(recordName: "current"))
        #expect(CloudBackupService.probeResult(forFetch: .success(record)) == .found(nil))
    }

    @Test func missingRecordMeansNoBackup() {
        #expect(CloudBackupService.probeResult(forFetch: nil) == .notFound)
        #expect(CloudBackupService.probeResult(forFetch: .failure(CKError(.unknownItem))) == .notFound)
        let id = CKRecord.ID(recordName: "current")
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: CKError(.unknownItem)]])
        #expect(CloudBackupService.probeResult(forFailure: partial) == .notFound)
    }

    @Test func signedOutAccountAsksForSignIn() {
        let signIn = CloudBackupError.iCloudUnavailable.localizedDescription
        for status in [CKAccountStatus.noAccount, .restricted, .couldNotDetermine, .temporarilyUnavailable] {
            #expect(CloudBackupService.probeResult(forAccountStatus: status) == .couldNotCheck(signIn))
        }
        #expect(CloudBackupService.probeResult(forAccountStatus: .available) == nil)
        #expect(CloudBackupService.probeResult(forFailure: CKError(.notAuthenticated)) == .couldNotCheck(signIn))
    }

    @Test func connectionFailureIsNotReportedAsNoBackup() {
        let error = CKError(.networkUnavailable)
        let result = CloudBackupService.probeResult(forFailure: error)
        guard case .couldNotCheck(let message) = result else {
            Issue.record("A network failure read as \(result)")
            return
        }
        #expect(message.hasPrefix(String(localized: "Couldn't reach iCloud. Check your connection and try again.")))
        #expect(message.contains(error.localizedDescription))
    }

    @Test func restoreErrorsKeepTheirOwnMessage() {
        #expect(CloudBackupService.userMessage(for: CloudBackupError.noBackup)
                == CloudBackupError.noBackup.localizedDescription)
        #expect(CloudBackupService.userMessage(for: CloudBackupError.needsNewerApp)
                == CloudBackupError.needsNewerApp.localizedDescription)
    }

    // MARK: - Restoring and importing together

    @Test func restoreCanHoldBackThePhonesOnboardingState() throws {
        let suite = "ReturningUserTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudBackupService.onboardingKey)
        defaults.set("phone", forKey: "phoneOnlySetting")

        CloudBackupService(defaults: defaults).applyValues(
            [CloudBackupService.onboardingKey: .bool(true), "weightUnit": .string("kg")],
            keeping: [CloudBackupService.onboardingKey]
        )

        #expect(defaults.object(forKey: CloudBackupService.onboardingKey) as? Bool == false)
        #expect(defaults.string(forKey: "weightUnit") == "kg")
        #expect(defaults.string(forKey: "phoneOnlySetting") == nil)
    }

    @Test func plainRestoreStillAppliesTheBackupsOnboardingState() throws {
        let suite = "ReturningUserTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudBackupService.onboardingKey)

        CloudBackupService(defaults: defaults).applyValues([CloudBackupService.onboardingKey: .bool(true)])

        #expect(defaults.bool(forKey: CloudBackupService.onboardingKey))
    }

    @Test func healthImportsRunAgainAfterARestore() throws {
        let suite = "ReturningUserTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(3, forKey: "healthKitWeightBackfillVersion")
        defaults.set(3, forKey: "healthKitBodyFatBackfillVersion")
        CloudBackupService(defaults: defaults).applyValues(["healthKitEnabled": .bool(true)])
        #expect(defaults.bool(forKey: "healthKitFoodRecoveryDone"))

        ReturningUser.reopenHealthImports(defaults: defaults)

        for key in ReturningUser.healthImportMarkers {
            #expect(defaults.object(forKey: key) == nil, "\(key) still blocks the import")
        }
        #expect(defaults.bool(forKey: "healthKitEnabled"))
    }

    @Test func afterARestoreOwnWeighInsMissingFromTheBackupComeBack() {
        let calendar = Calendar(identifier: .gregorian)
        let restoredDay = Date(timeIntervalSince1970: 1_790_000_000)
        let newerDay = restoredDay.addingTimeInterval(3 * 86_400)
        let restored = WeightEntry(date: restoredDay, weightKg: 80)
        let samples = [
            // The restored entry's own sample, read back with another value.
            WeightHealthSample(weightKg: 80.4, date: restoredDay, fudaiID: restored.id),
            // Logged in Fud AI after the backup was taken.
            WeightHealthSample(weightKg: 79.2, date: newerDay, fudaiID: UUID()),
        ]

        let skipped = WeightStore.healthImportCandidates(
            samples, existing: [restored], tombstones: [], restoringOwnHistory: false, calendar: calendar
        )
        let added = WeightStore.healthImportCandidates(
            samples, existing: [restored], tombstones: [], restoringOwnHistory: true, calendar: calendar
        )

        #expect(skipped.isEmpty)
        #expect(added.map(\.weightKg) == [79.2])
        #expect(added.first?.id == samples[1].fudaiID)
    }
}
