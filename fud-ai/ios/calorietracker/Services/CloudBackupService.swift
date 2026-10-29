import CloudKit
import Foundation
import Observation
import os

@Observable
final class CloudBackupService {
    static let enabledKey = "cloudBackupEnabled"
    static let lastAtKey = "cloudBackupLastAt"
    static let lastHashKey = "cloudBackupLastHash"
    static let onboardingKey = "hasCompletedOnboarding"
    static let smokeTestLaunchArgument = "-fudai.cloudBackup.smokeTest"
    static let smokeTestRecordName = "smoke-test"

    private static var didRunSmokeTestThisLaunch = false
    private static let archivePrefix = "fudai-backup-"
    /// Older builds kept their whole last backup in the temp folder under this name.
    private static let legacyArchiveName = "fudai-backup.zip"
    /// Temp archives a backup in this process is still packing or uploading.
    private static var activeArchiveNames: Set<String> = []
    private static let smokeLogger = Logger(subsystem: "com.apoorvdarshan.calorietracker", category: "CloudBackupSmoke")

    private let recordType = "FudAIBackup"
    private let recordName = "current"
    private let assetField = "backupAsset"
    private let shaField = "contentSha256"

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    var lastAt: String?
    var busy = false
    var hasCloudBackup = false
    var errorMessage: String?

    /// What a light presence check found, without downloading the backup.
    enum ProbeResult: Equatable {
        /// A backup exists; the date is when it was last saved (nil if CloudKit didn't say).
        case found(Date?)
        case notFound
        /// iCloud couldn't be asked. The message is ready to show.
        case couldNotCheck(String)
    }

    private let defaults: UserDefaults
    private var container: CKContainer { CKContainer.default() }
    /// Bumped by Delete All Data so a backup already in flight can't turn
    /// backup back on, or record a last-backup time, for the wiped phone.
    private var resetGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = defaults.bool(forKey: Self.enabledKey)
        self.lastAt = defaults.string(forKey: Self.lastAtKey)
        FoodImageStore.shared.removeAbandonedRestoreStaging()
    }

    func snapshotValues() -> [String: CloudBackupValue] {
        var out: [String: CloudBackupValue] = [:]
        for (key, raw) in defaults.dictionaryRepresentation() {
            guard CloudBackupPolicy.include(key) else { continue }
            if let data = raw as? Data {
                out[key] = .data(data)
            } else if let strings = raw as? [String] {
                out[key] = .stringArray(strings)
            } else if let string = raw as? String {
                out[key] = .string(string)
            } else if let number = raw as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    out[key] = .bool(number.boolValue)
                } else {
                    out[key] = .int(number.intValue)
                }
            }
        }
        return out
    }

    /// Writes the backup's settings over this phone's. Keys in `kept` stay as
    /// they are on the phone.
    func applyValues(_ values: [String: CloudBackupValue], keeping kept: Set<String> = []) {
        let restoredKeys = Set(values.keys)
        for key in defaults.dictionaryRepresentation().keys
        where CloudBackupPolicy.include(key) && !restoredKeys.contains(key) && !kept.contains(key) {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in values {
            guard CloudBackupPolicy.include(key), !kept.contains(key) else { continue }
            switch value.t {
            case "b":
                if let b = value.b { defaults.set(b, forKey: key) }
            case "i":
                if let i = value.i { defaults.set(i, forKey: key) }
            case "s":
                if let s = value.s { defaults.set(s, forKey: key) }
            case "d":
                if let d = value.d, let data = Data(base64Encoded: d) {
                    defaults.set(data, forKey: key)
                }
            case "ss":
                if let ss = value.ss { defaults.set(ss, forKey: key) }
            default:
                continue
            }
        }
        defaults.set(true, forKey: "healthKitFoodRecoveryDone")
        defaults.set(true, forKey: Self.enabledKey)
        enabled = true
    }

    /// Photo files and sizes only; bytes are read one photo at a time while packing.
    func snapshotPhotos() -> [String: CloudBackupPhotoFile] {
        var photos: [String: CloudBackupPhotoFile] = [:]
        for name in FoodImageStore.shared.filenames() {
            guard let safe = CloudBackupPolicy.safePhotoName(name),
                  let url = FoodImageStore.shared.fileURL(for: safe),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            photos[safe] = CloudBackupPhotoFile(url: url, size: size)
        }
        return photos
    }

    /// Restores `archive`'s photos into `store` and calls `applyValues` once
    /// they are in place. Every photo is read and staged first, so a failed
    /// read or write throws before any current photo or value changes and the
    /// diary never points at photos the restore removed. Runs without
    /// suspending, so no other main-actor work sees a half-finished restore;
    /// Compress Photos, which runs off the main actor, replaces no photo
    /// until it returns.
    static func restorePhotos(
        from archive: CloudBackupArchive.Reader,
        into store: FoodImageStore,
        applyValues: () -> Void
    ) throws {
        StoredPhotoCompressor.beginRestore()
        defer { StoredPhotoCompressor.endRestore() }
        let staging = try store.makeRestoreStaging()
        defer { staging.discard() }
        try archive.forEachPhoto { name, data in
            try store.stage(data, filename: name, in: staging)
        }
        try store.moveInStagedPhotos(staging)
        applyValues()
        // The restored diary uses only the restored photos.
        store.deletePhotos(notIn: staging.names)
    }

    func checkAccount() async throws {
        let status = try await container.accountStatus()
        guard status == .available else { throw CloudBackupError.iCloudUnavailable }
    }

    func refreshCloudPresence() async {
        do {
            try await checkAccount()
            hasCloudBackup = try await fetchRecord() != nil
        } catch {
            hasCloudBackup = false
        }
    }

    /// Checks whether this Apple ID has a backup without downloading it: only
    /// the small hash field of the "current" record is fetched, never the
    /// asset. Unlike `refreshCloudPresence`, a failed check is reported as
    /// such instead of looking like "no backup".
    func probeForBackup() async -> ProbeResult {
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            return Self.probeResult(forFailure: error)
        }
        if let unavailable = Self.probeResult(forAccountStatus: status) { return unavailable }
        let id = CKRecord.ID(recordName: recordName)
        let keys = [shaField]
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.timeoutIntervalForRequest = 20
        do {
            let results = try await container.privateCloudDatabase.configuredWith(configuration: configuration) { database in
                try await database.records(for: [id], desiredKeys: keys)
            }
            return Self.probeResult(forFetch: results[id])
        } catch {
            return Self.probeResult(forFailure: error)
        }
    }

    /// nil when the account is available and the record can be fetched.
    static func probeResult(forAccountStatus status: CKAccountStatus) -> ProbeResult? {
        guard status != .available else { return nil }
        return .couldNotCheck(CloudBackupError.iCloudUnavailable.localizedDescription)
    }

    /// Maps the per-record result of the probe fetch; a missing entry means no record.
    static func probeResult(forFetch result: Result<CKRecord, Error>?) -> ProbeResult {
        switch result {
        case .success(let record): return .found(record.modificationDate)
        case .failure(let error): return probeResult(forFailure: error)
        case nil: return .notFound
        }
    }

    static func probeResult(forFailure error: Error) -> ProbeResult {
        if let ckError = error as? CKError {
            if ckError.code == .unknownItem { return .notFound }
            if ckError.code == .partialFailure,
               let partial = ckError.partialErrorsByItemID, !partial.isEmpty,
               partial.values.allSatisfy({ ($0 as? CKError)?.code == .unknownItem }) {
                return .notFound
            }
        }
        return .couldNotCheck(userMessage(for: error))
    }

    /// Text for a failed iCloud check or restore. The app's own errors and a
    /// signed-out account keep their specific message; anything else is
    /// treated as a connection problem, with CloudKit's own text after it.
    static func userMessage(for error: Error) -> String {
        if let backupError = error as? CloudBackupError {
            return backupError.localizedDescription
        }
        if let ckError = error as? CKError, ckError.code == .notAuthenticated {
            return CloudBackupError.iCloudUnavailable.localizedDescription
        }
        let message = String(localized: "Couldn't reach iCloud. Check your connection and try again.")
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? message : message + "\n" + detail
    }

    /// Delete All Data wipes UserDefaults, but this service kept `enabled` and
    /// `lastAt` in memory, so the next background auto-backup could upload the
    /// near-empty phone over the user's real iCloud backup. Backup stays off
    /// until the user turns it on again.
    func turnOffAfterDeleteAllData() {
        resetGeneration += 1
        enabled = false
        lastAt = nil
        hasCloudBackup = false
        errorMessage = nil
        defaults.removeObject(forKey: Self.lastAtKey)
        defaults.removeObject(forKey: Self.lastHashKey)
    }

    func backupNow(skipIfUnchanged: Bool = false) async throws {
        busy = true
        defer { busy = false }
        let generation = resetGeneration
        try await checkAccount()
        // Delete All Data ran while the account check was pending: the
        // snapshot below would be the wiped phone.
        guard generation == resetGeneration else { return }
        let values = snapshotValues()
        let photos = snapshotPhotos()
        let hash = CloudBackupArchive.contentHash(values: values, photoSizes: photos.mapValues(\.size))
        if skipIfUnchanged, hash == defaults.string(forKey: Self.lastHashKey) { return }
        let zip = try packToTemporaryFile(values: values, photos: photos)
        defer { removeTemporaryArchive(zip) }
        try await upload(zip: zip, hash: hash)
        // The upload holds the data from before the wipe; just don't turn
        // backup back on for the wiped phone.
        guard generation == resetGeneration else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        defaults.set(now, forKey: Self.lastAtKey)
        defaults.set(hash, forKey: Self.lastHashKey)
        lastAt = now
        enabled = true
        hasCloudBackup = true
    }

    /// `holdingOnboarding` leaves this phone's hasCompletedOnboarding as it is,
    /// so the welcome-back screen can finish its other steps before the app
    /// opens. Returns whether the backup had finished setup.
    @discardableResult
    func restoreNow(holdingOnboarding: Bool = false) async throws -> Bool {
        busy = true
        defer { busy = false }
        try await checkAccount()
        guard let record = try await fetchRecord(),
              let asset = record[assetField] as? CKAsset,
              let url = asset.fileURL
        else { throw CloudBackupError.noBackup }
        let archive = try CloudBackupArchive.Reader(url: url)
        let document = archive.document
        let values = document.payload.values
        let kept: Set<String> = holdingOnboarding ? [Self.onboardingKey] : []
        try Self.restorePhotos(from: archive, into: FoodImageStore.shared) {
            applyValues(values, keeping: kept)
        }
        defaults.set(document.contentSha256, forKey: Self.lastHashKey)
        defaults.set(document.exportedAt, forKey: Self.lastAtKey)
        lastAt = document.exportedAt
        NotificationCenter.default.post(name: .cloudBackupDidRestore, object: nil)
        return values[Self.onboardingKey]?.b == true
    }

    func deleteCloudBackup() async throws {
        busy = true
        defer { busy = false }
        try await deleteCloudRecord(named: recordName)
    }

    func autoBackupIfNeeded() async {
        guard enabled else { return }
        // Mid-setup (a welcome-back restore holds setup open until the user opens
        // the app) the phone isn't a finished copy; uploading it would replace a
        // backup's finished setup with an unfinished one.
        guard defaults.bool(forKey: Self.onboardingKey) else { return }
        guard isUnmetered() else { return }
        if let last = lastAt,
           let date = ISO8601DateFormatter().date(from: last),
           Date().timeIntervalSince(date) < CloudBackupPolicy.minAutoBackupInterval {
            return
        }
        try? await backupNow(skipIfUnchanged: true)
    }

    /// Release-safe CloudKit integration check: upload → download → delete.
    /// Logs `FudAICloudBackupSmokeTest: PASS` or `FAIL: <reason>` to stdout and os_log.
    func runSmokeTestIfRequested() async {
        guard CommandLine.arguments.contains(Self.smokeTestLaunchArgument) else { return }
        guard !Self.didRunSmokeTestThisLaunch else { return }
        Self.didRunSmokeTestThisLaunch = true
        await runSmokeTest()
    }

    func runSmokeTest() async {
        var smokeUploaded = false

        do {
            try await checkAccount()
            let values = snapshotValues()
            let photos = snapshotPhotos()
            let hash = CloudBackupArchive.contentHash(values: values, photoSizes: photos.mapValues(\.size))
            let zip = try packToTemporaryFile(values: values, photos: photos)
            defer { removeTemporaryArchive(zip) }
            try await upload(zip: zip, hash: hash, toRecord: Self.smokeTestRecordName)
            smokeUploaded = true

            guard let record = try await fetchRecord(named: Self.smokeTestRecordName) else {
                logSmokeTestFailure("backup record missing after upload")
                return
            }
            try validateDownloadedBackup(record: record, expectedHash: hash)

            try await deleteCloudRecord(named: Self.smokeTestRecordName)
            smokeUploaded = false

            guard try await fetchRecord(named: Self.smokeTestRecordName) == nil else {
                logSmokeTestFailure("record still present after delete")
                return
            }
            logSmokeTestPass()
        } catch {
            logSmokeTestFailure(error.localizedDescription)
        }

        if smokeUploaded {
            try? await deleteCloudRecord(named: Self.smokeTestRecordName)
        }
    }

    private func logSmokeTestPass() {
        let line = "FudAICloudBackupSmokeTest: PASS"
        print(line)
        Self.smokeLogger.info("\(line, privacy: .public)")
    }

    private func logSmokeTestFailure(_ reason: String) {
        let line = "FudAICloudBackupSmokeTest: FAIL: \(reason)"
        print(line)
        Self.smokeLogger.error("\(line, privacy: .public)")
    }

    /// Packs into a uniquely named temp file; the caller passes it to
    /// `removeTemporaryArchive` once CloudKit has saved it.
    private func packToTemporaryFile(values: [String: CloudBackupValue], photos: [String: CloudBackupPhotoFile]) throws -> URL {
        let temp = FileManager.default.temporaryDirectory
        Self.removeAbandonedArchives(in: temp, keeping: Self.activeArchiveNames)
        let zip = temp.appendingPathComponent("\(Self.archivePrefix)\(UUID().uuidString).zip")
        Self.activeArchiveNames.insert(zip.lastPathComponent)
        do {
            try CloudBackupArchive.pack(
                to: zip,
                values: values,
                photos: photos,
                exportedAt: ISO8601DateFormatter().string(from: Date()),
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            )
        } catch {
            removeTemporaryArchive(zip)
            throw error
        }
        return zip
    }

    private func removeTemporaryArchive(_ zip: URL) {
        try? FileManager.default.removeItem(at: zip)
        Self.activeArchiveNames.remove(zip.lastPathComponent)
    }

    /// Deletes backup archives in `directory` that a killed process left while
    /// packing or uploading, and the fixed-name file older builds kept there.
    /// Names in `active` belong to a backup still running and are kept.
    static func removeAbandonedArchives(in directory: URL, keeping active: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where !active.contains(name) {
            let isArchive = name == legacyArchiveName || (name.hasPrefix(archivePrefix) && name.hasSuffix(".zip"))
            guard isArchive else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func upload(zip: URL, hash: String, toRecord named: String? = nil) async throws {
        let name = named ?? recordName
        let id = CKRecord.ID(recordName: name)
        let record = (try? await fetchRecord(named: name)) ?? CKRecord(recordType: recordType, recordID: id)
        record[assetField] = CKAsset(fileURL: zip)
        record[shaField] = hash as CKRecordValue
        _ = try await container.privateCloudDatabase.save(record)
    }

    private func fetchRecord(named name: String? = nil) async throws -> CKRecord? {
        let id = CKRecord.ID(recordName: name ?? recordName)
        do {
            return try await container.privateCloudDatabase.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func deleteCloudRecord(named name: String) async throws {
        try await checkAccount()
        let id = CKRecord.ID(recordName: name)
        do {
            try await container.privateCloudDatabase.deleteRecord(withID: id)
        } catch let error as CKError where error.code == .unknownItem {
            // already gone
        }
        guard name == recordName else { return }
        hasCloudBackup = false
        defaults.removeObject(forKey: Self.lastAtKey)
        defaults.removeObject(forKey: Self.lastHashKey)
        lastAt = nil
    }

    private func validateDownloadedBackup(record: CKRecord, expectedHash: String) throws {
        guard let asset = record[assetField] as? CKAsset,
              let url = asset.fileURL
        else { throw CloudBackupError.noBackup }
        let document = try CloudBackupArchive.Reader(url: url).document
        guard document.contentSha256 == expectedHash else { throw CloudBackupError.invalidFormat }
        if let recordSha = record[shaField] as? String, recordSha != expectedHash {
            throw CloudBackupError.invalidFormat
        }
    }

    private func isUnmetered() -> Bool { true }
}

extension Notification.Name {
    static let cloudBackupDidRestore = Notification.Name("ai.fud.cloudBackupDidRestore")
}
