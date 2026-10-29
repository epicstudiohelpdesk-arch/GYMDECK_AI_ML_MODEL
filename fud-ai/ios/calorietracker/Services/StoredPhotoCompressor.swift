import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Keeps stored meal and exercise photos at the size the app can actually show.
///
/// The full-screen viewer never decodes more than `FoodImageStore.viewerMaxDimension`, so
/// pixels beyond it only cost storage and backup space. New photos are downscaled in the
/// background right after they are stored; existing ones only when the user confirms Compress
/// Photos in Settings. Backup restores, migrated legacy photos and images already within the
/// cap keep their original bytes, and so does any photo whose re-encoded copy isn't smaller.
/// Nothing is replaced while a backup restore is staging or moving photos in, and a queued
/// new-photo job skips a photo that a restore or a later save replaced before the job ran.
nonisolated enum StoredPhotoCompressor {
    /// Longest side kept for stored photos (matches `FoodImageStore.viewerMaxDimension`).
    static let maxPixelSize = 2048
    static let jpegQuality = 0.8

    struct Result: Equatable, Sendable {
        var compressedCount = 0
        var unreadableCount = 0
        /// Photos left as they were because staging or replacing the smaller copy failed
        /// (for example when the device is out of space), or because a backup restore was
        /// replacing photos at the time.
        var failedCount = 0
        var bytesSaved: Int64 = 0
    }

    /// Serial queue that downscales newly stored photos off the main actor.
    static let newPhotoQueue = DispatchQueue(label: "com.apoorvdarshan.calorietracker.new-photo-downscale", qos: .utility)

    /// Serializes photo writes and deletes with the compressor's last unchanged-file check and
    /// swap, so a photo saved, restored or deleted mid-compression is never replaced by a copy
    /// of the older bytes. Held only around single file operations.
    private static let photoFileLock = NSLock()

    /// Backup restores between `beginRestore` and `endRestore`. Guarded by `photoFileLock`, so
    /// the compressor checks it in the same step as its swap.
    nonisolated(unsafe) private static var restoresRunning = 0

    static func withPhotoFileLock<T>(_ body: () throws -> T) rethrows -> T {
        photoFileLock.lock()
        defer { photoFileLock.unlock() }
        return try body()
    }

    /// Brackets a backup restore, from staging its photos to deleting the ones it lacks. In
    /// between, no photo is replaced by a compressed copy.
    static func beginRestore() {
        withPhotoFileLock { restoresRunning += 1 }
    }

    static func endRestore() {
        withPhotoFileLock { restoresRunning -= 1 }
    }

    static var isRestoring: Bool {
        withPhotoFileLock { restoresRunning > 0 }
    }

    /// Which file is at a path: its file system and file number, size and modification date.
    /// Every save, restore or delete replaces the file or changes its size or date, so a
    /// different identity means the path no longer holds the file that was checked earlier.
    struct FileIdentity: Equatable, Sendable {
        let fileSystemNumber: Int64?
        let fileNumber: UInt64?
        let size: Int64
        let modified: Date
    }

    /// Identity of the item at `url` (not following a symbolic link), or nil when nothing is there.
    static func fileIdentity(of url: URL) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        return FileIdentity(
            fileSystemNumber: (attributes[.systemNumber] as? NSNumber)?.int64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            size: size,
            modified: modified
        )
    }

    /// Queues `url` (a photo `FoodImageStore` just wrote, with the `identity` it had right after
    /// that write) to be capped at `maxPixelSize` with the same swap rules as Compress Photos, so
    /// the caller never waits for the decode and encode. The job leaves the photo alone when the
    /// path no longer holds that file by the time it runs: a backup restore, a newer save or a
    /// delete in the meantime replaced it, and restored bytes must stay as they are.
    static func downscaleNewPhotoInBackground(
        at url: URL,
        expecting identity: FileIdentity,
        maxPixelSize: Int = maxPixelSize
    ) {
        newPhotoQueue.async {
            _ = autoreleasepool { compressPhoto(at: url, expecting: identity, maxPixelSize: maxPixelSize) }
        }
    }

    /// An upright JPEG capped at `maxPixelSize` on the longest side, or nil when the image is
    /// already within the cap or can't be decoded — callers then keep the original bytes.
    static func downscaledJPEGData(_ data: Data, maxPixelSize: Int = maxPixelSize) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return downscaledJPEGData(from: source, maxPixelSize: maxPixelSize)
    }

    /// Longest side in pixels as stored (before orientation), or nil when unreadable.
    static func longestSide(of data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return longestSide(of: source)
    }

    /// Downscales photos in `folder` that exceed `maxPixelSize`, one file at a time inside an
    /// autorelease pool so only one bounded image is in memory. Each result is staged in a
    /// replacement directory and swapped in only when it is smaller and the original is
    /// unchanged; files that can't be decoded, or whose copy couldn't be written, are left as
    /// they are and counted. Filenames never change, and thumbnails stay valid because both
    /// versions decode upright. Only plain photo names directly inside `folder` (no symbolic
    /// links) are touched, and photos reached while a backup restore runs count as failed.
    static func compressPhotos(
        in folder: URL,
        maxPixelSize: Int = maxPixelSize,
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) -> Result {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .compactMap { FoodImageStore.photoURL(named: $0.lastPathComponent, inside: folder) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var result = Result()
        for (index, file) in files.enumerated() {
            let outcome = autoreleasepool { compressPhoto(at: file, maxPixelSize: maxPixelSize) }
            switch outcome {
            case .compressed(let saved):
                result.compressedCount += 1
                result.bytesSaved += saved
            case .unchanged:
                break
            case .unreadable:
                result.unreadableCount += 1
            case .failed:
                result.failedCount += 1
            }
            progress(index + 1, files.count)
        }
        return result
    }

    // MARK: - Private

    private enum Outcome {
        case compressed(Int64)
        case unchanged
        case unreadable
        case failed
    }

    /// `expected` is the file a queued new-photo job was queued for; when the path now holds
    /// another file the photo is left alone.
    private static func compressPhoto(at url: URL, expecting expected: FileIdentity? = nil, maxPixelSize: Int) -> Outcome {
        guard !isRestoring else { return .failed }
        let fileManager = FileManager.default
        guard let before = fileIdentity(of: url) else { return .unchanged }
        if let expected, before != expected { return .unchanged }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let longest = longestSide(of: source) else {
            return .unreadable
        }
        guard longest > maxPixelSize else { return .unchanged }
        guard let image = downscaledImage(from: source, maxPixelSize: maxPixelSize) else { return .unreadable }
        guard let data = jpegData(from: image) else { return .failed }
        // A copy that isn't smaller (an already heavily compressed photo) is never swapped in.
        guard Int64(data.count) < before.size else { return .unchanged }

        do {
            let staging = try fileManager.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: url,
                create: true
            )
            defer { try? fileManager.removeItem(at: staging) }
            let staged = staging.appendingPathComponent(url.lastPathComponent)
            try data.write(to: staged)
            return try withPhotoFileLock { () throws -> Outcome in
                // A restore that started while this photo was encoded owns the folder until it ends.
                guard restoresRunning == 0 else { return .failed }
                // Skip if the photo was deleted, restored or rewritten while it was being encoded.
                guard fileIdentity(of: url) == before else { return .unchanged }
                _ = try fileManager.replaceItemAt(url, withItemAt: staged)
                return .compressed(before.size - Int64(data.count))
            }
        } catch {
            return .failed
        }
    }

    private static func downscaledJPEGData(from source: CGImageSource, maxPixelSize: Int) -> Data? {
        guard let longest = longestSide(of: source), longest > maxPixelSize,
              let image = downscaledImage(from: source, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return jpegData(from: image)
    }

    private static func downscaledImage(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // Bakes EXIF orientation into the pixels; the JPEG below carries no orientation tag.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func longestSide(of source: CGImageSource) -> Int? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            return nil
        }
        return max(width, height)
    }
}
