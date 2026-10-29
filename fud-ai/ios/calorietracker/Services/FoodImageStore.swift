import Foundation
import ImageIO
import UIKit

/// Disk-backed image store for `FoodEntry` photos.
///
/// Photos used to be stored inline as base64 `Data` inside the `foodEntries`
/// JSON blob in `UserDefaults`. That breaks past ~15-20 photos because iOS
/// silently drops any UserDefaults write >= 4 MiB — `saveEntries()` would
/// appear to succeed while the last-successful snapshot was actually locked
/// in place (phantom adds/deletes on relaunch).
///
/// Now images live as individual JPEGs under
/// `Application Support/fudai-food-images/<uuid>.jpg`, and `FoodEntry`
/// persists only the filename. The encoded entry JSON is tiny — a few
/// hundred bytes per entry — so UserDefaults stays well under its cap.
struct FoodImageStore {
    static let shared = FoodImageStore()
    static let thumbnailMaxDimension = 320
    static let viewerMaxDimension = 2048

    private let folderName = "fudai-food-images"
    private let thumbnailFolderName = "fudai-food-thumbnails-v2"
    // A restore writes its photos here first and moves them in only once every
    // one of them has been read and written.
    private let restoreStagingFolderName = "fudai-food-images-restore"
    private let restoreStagingThumbnailFolderName = "fudai-food-thumbnails-restore"

    /// Application Support unless a test points the store at its own folder.
    private let baseURLOverride: URL?

    init(baseURL: URL? = nil) {
        baseURLOverride = baseURL
    }

    private let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 12 * 1_024 * 1_024
        return cache
    }()

    private var baseURL: URL? {
        if let baseURLOverride { return baseURLOverride }
        return try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private var folderURL: URL? {
        guard let base = baseURL else { return nil }
        let url = base.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    private var thumbnailFolderURL: URL? {
        guard let base = baseURL else { return nil }
        let url = base.appendingPathComponent(thumbnailFolderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        // Legacy thumbnails lost EXIF orientation during compression.
        let legacyURL = base.appendingPathComponent("fudai-food-thumbnails", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        return url
    }

    /// Writes `data` to disk under a stable filename derived from `id`.
    /// Returns the filename (not full path) on success.
    @discardableResult
    func store(data: Data, for id: UUID) -> String? {
        store(data: data, filename: "\(id.uuidString).jpg")
    }

    /// Writes an additional image for the same entry without overwriting the
    /// primary `<uuid>.jpg` file.
    @discardableResult
    func store(data: Data, for id: UUID, index: Int) -> String? {
        store(data: data, filename: "\(id.uuidString)-\(index).jpg")
    }

    /// Moves a photo that an older build kept inline in the diary JSON to disk with its bytes
    /// unchanged: existing photos are only ever re-encoded by a confirmed Compress Photos.
    @discardableResult
    func storeLegacyInlinePhoto(data: Data, for id: UUID) -> String? {
        store(data: data, filename: "\(id.uuidString).jpg", downscalingLargePhotos: false)
    }

    /// Writes the bytes as given and returns at once. New photos over
    /// `StoredPhotoCompressor.maxPixelSize` are then capped to an upright JPEG at that size (the
    /// viewer never decodes more) on a background queue, and only when that copy is smaller;
    /// smaller or undecodable images keep their bytes.
    private func store(data: Data, filename: String, downscalingLargePhotos: Bool = true) -> String? {
        guard let folderURL else { return nil }
        let url = folderURL.appendingPathComponent(filename)
        do {
            // The identity is read under the same lock as the write, so the queued downscale
            // touches only this file and never one a restore or a later save put at `url`.
            let written = try StoredPhotoCompressor.withPhotoFileLock { () throws -> StoredPhotoCompressor.FileIdentity? in
                try data.write(to: url, options: .atomic)
                return StoredPhotoCompressor.fileIdentity(of: url)
            }
            if let thumbnail = decodeImage(at: url, maxPixelSize: Self.thumbnailMaxDimension) {
                writeThumbnail(thumbnail, filename: filename)
            }
            if downscalingLargePhotos, let written,
               let longest = StoredPhotoCompressor.longestSide(of: data),
               longest > StoredPhotoCompressor.maxPixelSize {
                StoredPhotoCompressor.downscaleNewPhotoInBackground(at: url, expecting: written)
            }
            return filename
        } catch {
            return nil
        }
    }

    func filenames() -> [String] {
        guard let folderURL else { return [] }
        return (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []
    }

    /// Folder of stored photos, for Settings › Storage and Compress Photos.
    var photoFolderURL: URL? { folderURL }

    /// Folder of regenerable thumbnails, for Settings › Storage.
    var thumbnailCacheFolderURL: URL? { thumbnailFolderURL }

    /// Deletes cached thumbnails only; `loadThumbnail` rebuilds them from the photos on demand.
    /// The folder can hold thousands of files, so it is removed off the main actor.
    func clearThumbnailCache() async {
        thumbnailCache.removeAllObjects()
        guard let thumbFolderURL = thumbnailFolderURL else { return }
        await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: thumbFolderURL)
        }.value
        thumbnailCache.removeAllObjects()
    }

    /// Reads the bytes at `filename` (not a full path), or nil if missing.
    func load(filename: String) -> Data? {
        guard let folderURL else { return nil }
        let url = folderURL.appendingPathComponent(filename)
        return try? Data(contentsOf: url)
    }

    /// Bounded decode for list rows — avoids full-resolution JPEG decode on Home.
    func loadThumbnail(filename: String, maxPixelSize: Int = thumbnailMaxDimension) -> UIImage? {
        let cacheKey = "\(filename):\(maxPixelSize)" as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        if let thumbFolderURL = thumbnailFolderURL {
            let thumbURL = thumbFolderURL.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: thumbURL.path),
               let image = decodeImage(at: thumbURL, maxPixelSize: maxPixelSize) {
                thumbnailCache.setObject(image, forKey: cacheKey, cost: image.estimatedMemoryCost)
                return image
            }
        }

        guard let sourceURL = fileURL(for: filename),
              let image = decodeImage(at: sourceURL, maxPixelSize: maxPixelSize) else {
            return nil
        }

        writeThumbnail(image, filename: filename)
        thumbnailCache.setObject(image, forKey: cacheKey, cost: image.estimatedMemoryCost)
        return image
    }

    /// Bounded decode for full-screen viewer — original bytes stay untouched on disk.
    func loadForViewer(filename: String, maxPixelSize: Int = viewerMaxDimension) -> UIImage? {
        guard let sourceURL = fileURL(for: filename) else { return nil }
        return decodeImage(at: sourceURL, maxPixelSize: maxPixelSize)
    }

    /// On-disk URL for a stored filename, when the file exists.
    func fileURL(for filename: String) -> URL? {
        guard let folderURL else { return nil }
        let url = folderURL.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Stores a user exercise photo under a fresh filename (never overwrites diary snapshots).
    @discardableResult
    func storeExercisePhoto(data: Data) -> String? {
        store(data: data, filename: UserExercise.newPhotoFilename())
    }

    /// Best-effort delete. Silent no-op if the file is already gone.
    func delete(filename: String) {
        guard let folderURL else { return }
        let url = folderURL.appendingPathComponent(filename)
        StoredPhotoCompressor.withPhotoFileLock {
            _ = try? FileManager.default.removeItem(at: url)
        }
        if let thumbFolderURL = thumbnailFolderURL {
            let thumbURL = thumbFolderURL.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: thumbURL)
        }
        evictThumbnailCache(for: filename)
    }

    /// Wipes the entire image folder (used by Delete All Data).
    func deleteAll() {
        guard let folderURL else { return }
        StoredPhotoCompressor.withPhotoFileLock {
            _ = try? FileManager.default.removeItem(at: folderURL)
        }
        if let thumbFolderURL = thumbnailFolderURL {
            try? FileManager.default.removeItem(at: thumbFolderURL)
        }
        thumbnailCache.removeAllObjects()
    }

    // MARK: - Restore

    /// Empty staging folders beside the photo folder, so moving photos in is a
    /// rename. Anything an interrupted restore left there is removed first.
    func makeRestoreStaging() throws -> CloudBackupPhotoStaging {
        guard let base = baseURL else { throw CocoaError(.fileNoSuchFile) }
        return try CloudBackupPhotoStaging(
            folder: base.appendingPathComponent(restoreStagingFolderName, isDirectory: true),
            thumbnailFolder: base.appendingPathComponent(restoreStagingThumbnailFolderName, isDirectory: true)
        )
    }

    /// Removes staging left by a restore the system killed. A restore stages,
    /// moves in and discards without suspending, so none is running whenever
    /// other main-actor code gets to call this.
    func removeAbandonedRestoreStaging() {
        guard let base = baseURL else { return }
        try? FileManager.default.removeItem(at: base.appendingPathComponent(restoreStagingFolderName, isDirectory: true))
        try? FileManager.default.removeItem(at: base.appendingPathComponent(restoreStagingThumbnailFolderName, isDirectory: true))
    }

    /// Writes one restored photo byte-identical (restores are never
    /// re-compressed), and its thumbnail when it decodes, into `staging`.
    /// Throws if `filename` is not a plain photo name inside the staging
    /// folder or the write fails; current photos are never touched.
    func stage(_ data: Data, filename: String, in staging: CloudBackupPhotoStaging) throws {
        guard let url = Self.photoURL(named: filename, inside: staging.folder) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try data.write(to: url, options: .atomic)
        if let thumbnail = decodeImage(at: url, maxPixelSize: Self.thumbnailMaxDimension),
           let jpeg = thumbnail.jpegData(compressionQuality: 0.76),
           let thumbnailURL = Self.photoURL(named: filename, inside: staging.thumbnailFolder) {
            try? jpeg.write(to: thumbnailURL, options: .atomic)
        }
        staging.record(url.lastPathComponent)
    }

    /// Moves every staged photo into the photo folder, replacing any with the
    /// same name, and drops the old thumbnail of a replaced photo that has no
    /// staged one. Photos the restore lacks stay until `deletePhotos(notIn:)`.
    func moveInStagedPhotos(_ staging: CloudBackupPhotoStaging) throws {
        guard let folderURL else { throw CocoaError(.fileNoSuchFile) }
        let thumbFolderURL = thumbnailFolderURL
        defer { thumbnailCache.removeAllObjects() }
        for name in staging.names.sorted() {
            guard let source = Self.photoURL(named: name, inside: staging.folder),
                  let target = Self.photoURL(named: name, inside: folderURL)
            else { throw CocoaError(.fileWriteInvalidFileName) }
            // Under the lock Compress Photos swaps in, so it never replaces a
            // photo with a copy of the bytes this move just replaced.
            try StoredPhotoCompressor.withPhotoFileLock {
                try Self.move(source, replacing: target)
            }
            guard let thumbFolderURL,
                  let thumbnailTarget = Self.photoURL(named: name, inside: thumbFolderURL)
            else { continue }
            var movedThumbnail = false
            if let stagedThumbnail = Self.photoURL(named: name, inside: staging.thumbnailFolder),
               FileManager.default.fileExists(atPath: stagedThumbnail.path) {
                movedThumbnail = (try? Self.move(stagedThumbnail, replacing: thumbnailTarget)) != nil
            }
            if !movedThumbnail { try? FileManager.default.removeItem(at: thumbnailTarget) }
        }
    }

    /// Deletes every photo not named in `keep`. A restore calls this once the
    /// restored diary, which uses only the restored photos, is saved.
    func deletePhotos(notIn keep: Set<String>) {
        for name in filenames() where !keep.contains(name) {
            delete(filename: name)
        }
    }

    /// `folder`/`filename` for a plain photo name whose path stays a direct
    /// child of `folder` and is not a symbolic link; nil otherwise. Restored
    /// names come from a downloaded archive, so a crafted one cannot reach
    /// outside the folder. Compress Photos, off the main actor, uses the same
    /// check to touch only plain photos in the photo folder.
    nonisolated static func photoURL(named filename: String, inside folder: URL) -> URL? {
        guard let name = CloudBackupPolicy.safePhotoName(filename) else { return nil }
        let root = folder.standardizedFileURL
        let url = root.appendingPathComponent(name, isDirectory: false)
        guard url.lastPathComponent == name,
              url.deletingLastPathComponent().standardizedFileURL.path == root.path
        else { return nil }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return nil }
        return url
    }

    private static func move(_ source: URL, replacing target: URL) throws {
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: target)
        }
    }

    private func writeThumbnail(_ image: UIImage, filename: String) {
        guard let thumbFolderURL = thumbnailFolderURL,
              let data = image.jpegData(compressionQuality: 0.76) else { return }
        let url = thumbFolderURL.appendingPathComponent(filename)
        try? data.write(to: url, options: .atomic)
    }

    private func evictThumbnailCache(for filename: String) {
        thumbnailCache.removeObject(forKey: "\(filename):\(Self.thumbnailMaxDimension)" as NSString)
    }

    private func decodeImage(at url: URL, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return UIImage(contentsOfFile: url.path)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(contentsOfFile: url.path)
        }
        return UIImage(cgImage: cgImage)
    }
}

/// Where a restore writes its photos before any current photo changes.
final class CloudBackupPhotoStaging {
    let folder: URL
    let thumbnailFolder: URL
    /// Photos staged so far, by file name.
    private(set) var names: Set<String> = []

    /// Creates empty folders, removing anything an interrupted restore left.
    init(folder: URL, thumbnailFolder: URL) throws {
        self.folder = folder
        self.thumbnailFolder = thumbnailFolder
        discard()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbnailFolder, withIntermediateDirectories: true)
    }

    fileprivate func record(_ name: String) {
        names.insert(name)
    }

    func discard() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: thumbnailFolder)
    }
}

private extension UIImage {
    var estimatedMemoryCost: Int {
        let pixelWidth = max(Int(size.width * scale), 1)
        let pixelHeight = max(Int(size.height * scale), 1)
        return pixelWidth * pixelHeight * 4
    }
}
