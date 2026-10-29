import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import calorietracker

@MainActor
struct StoredPhotoCompressorTests {
    @Test func storedCapMatchesTheViewerDecodeCap() {
        #expect(StoredPhotoCompressor.maxPixelSize == FoodImageStore.viewerMaxDimension)
    }

    @Test func largePhotoIsDownscaledUprightWithOrientationBakedIn() throws {
        // Landscape pixels tagged "rotate 90° CW" display as portrait.
        let large = try jpegData(width: 3_000, height: 2_000, orientation: .right)

        let downscaled = try #require(StoredPhotoCompressor.downscaledJPEGData(large))
        let info = try imageInfo(downscaled)

        #expect(max(info.width, info.height) <= StoredPhotoCompressor.maxPixelSize)
        #expect(max(info.width, info.height) > StoredPhotoCompressor.maxPixelSize - 8)
        #expect(info.height > info.width)
        #expect(info.orientation == 1)
    }

    @Test func smallOrUndecodableDataIsNotReencoded() throws {
        #expect(StoredPhotoCompressor.downscaledJPEGData(try jpegData(width: 1_200, height: 900)) == nil)
        #expect(StoredPhotoCompressor.downscaledJPEGData(Data("not an image".utf8)) == nil)
    }

    @Test func newPhotosAreCappedWhileSmallPhotosAndRestoresKeepTheirBytes() throws {
        let large = try jpegData(width: 3_000, height: 2_000)
        let small = try jpegData(width: 1_200, height: 900)
        let largeName = try #require(FoodImageStore.shared.store(data: large, for: UUID()))
        let smallName = try #require(FoodImageStore.shared.store(data: small, for: UUID()))
        defer { [largeName, smallName].forEach { FoodImageStore.shared.delete(filename: $0) } }
        // A restore stages the backup's bytes and moves them into the photo folder as they are.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoredPhotoCompressorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let restoreStore = FoodImageStore(baseURL: base)
        let restoredName = "\(UUID().uuidString).jpg"
        let staging = try restoreStore.makeRestoreStaging()
        defer { staging.discard() }
        try restoreStore.stage(large, filename: restoredName, in: staging)
        try restoreStore.moveInStagedPhotos(staging)
        // The cap is applied off the main actor right after the save.
        StoredPhotoCompressor.newPhotoQueue.sync {}

        let stored = try imageInfo(try #require(FoodImageStore.shared.load(filename: largeName)))
        #expect(max(stored.width, stored.height) <= StoredPhotoCompressor.maxPixelSize)
        #expect(FoodImageStore.shared.load(filename: smallName) == small)
        #expect(restoreStore.load(filename: restoredName) == large)
    }

    @Test func fileIdentityChangesWhenAPhotoIsReplacedEvenWithTheSameBytes() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoredPhotoCompressorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("meal.jpg")
        let photo = Data(repeating: 7, count: 4_096)
        try photo.write(to: url, options: .atomic)

        let saved = try #require(StoredPhotoCompressor.fileIdentity(of: url))
        #expect(StoredPhotoCompressor.fileIdentity(of: url) == saved)

        // A restore moves its staged copy over the photo; the bytes and size can be the same.
        let staged = folder.appendingPathComponent("staged.jpg")
        try photo.write(to: staged)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
        let restored = try #require(StoredPhotoCompressor.fileIdentity(of: url))
        #expect(restored.size == saved.size)
        #expect(restored != saved)

        try FileManager.default.removeItem(at: url)
        #expect(StoredPhotoCompressor.fileIdentity(of: url) == nil)
    }

    @Test func queuedNewPhotoJobLeavesAPhotoARestoreReplacedBeforeTheJobRan() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoredPhotoCompressorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = FoodImageStore(baseURL: base)
        let large = try jpegData(width: 3_000, height: 2_000)
        // Hold the serial queue so the job queued by the save starts only after the restore
        // has finished (and its restore guard no longer applies).
        let gate = DispatchSemaphore(value: 0)
        StoredPhotoCompressor.newPhotoQueue.async { gate.wait() }
        let saved = store.store(data: large, for: UUID())
        let restore = Result { () throws -> Void in
            guard let name = saved else { throw CocoaError(.fileWriteUnknown) }
            let staging = try store.makeRestoreStaging()
            defer { staging.discard() }
            // The backup holds the same bytes, so only the file itself differs.
            try store.stage(large, filename: name, in: staging)
            try store.moveInStagedPhotos(staging)
        }
        gate.signal()
        StoredPhotoCompressor.newPhotoQueue.sync {}

        try restore.get()
        let name = try #require(saved)
        #expect(!StoredPhotoCompressor.isRestoring)
        #expect(store.load(filename: name) == large)

        // A save that no restore replaced is still capped.
        let kept = try #require(store.store(data: large, for: UUID()))
        StoredPhotoCompressor.newPhotoQueue.sync {}
        let info = try imageInfo(try #require(store.load(filename: kept)))
        #expect(max(info.width, info.height) <= StoredPhotoCompressor.maxPixelSize)
    }

    @Test func compressionReplacesNothingWhileABackupRestoreRuns() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoredPhotoCompressorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let large = try jpegData(width: 3_000, height: 2_000)
        try large.write(to: folder.appendingPathComponent("meal.jpg"))

        StoredPhotoCompressor.beginRestore()
        let duringRestore = StoredPhotoCompressor.compressPhotos(in: folder)
        StoredPhotoCompressor.endRestore()

        // Reported as failed so the user can run it again once the restore is done.
        #expect(duringRestore == StoredPhotoCompressor.Result(failedCount: 1))
        #expect(try Data(contentsOf: folder.appendingPathComponent("meal.jpg")) == large)
        #expect(!StoredPhotoCompressor.isRestoring)
        #expect(StoredPhotoCompressor.compressPhotos(in: folder).compressedCount == 1)
    }

    @Test func compressionOnlyTouchesPlainPhotoNamesDirectlyInsideTheFolder() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoredPhotoCompressorTests-\(UUID().uuidString)", isDirectory: true)
        let folder = base.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let large = try jpegData(width: 3_000, height: 2_000)
        try large.write(to: folder.appendingPathComponent("meal.jpg"))
        try large.write(to: folder.appendingPathComponent("notes.txt"))
        try large.write(to: folder.appendingPathComponent("nested/inner.jpg"))
        let outside = base.appendingPathComponent("outside.jpg")
        try large.write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.jpg"), withDestinationURL: outside)
        var progress: [[Int]] = []

        let result = StoredPhotoCompressor.compressPhotos(in: folder) { done, total in progress.append([done, total]) }

        #expect(result.compressedCount == 1)
        #expect(progress == [[1, 1]])
        #expect(try Data(contentsOf: folder.appendingPathComponent("meal.jpg")).count < large.count)
        #expect(try Data(contentsOf: folder.appendingPathComponent("notes.txt")) == large)
        #expect(try Data(contentsOf: folder.appendingPathComponent("nested/inner.jpg")) == large)
        #expect(try Data(contentsOf: outside) == large)
        let link = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("link.jpg").path)
        #expect(link[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test func photosWhoseDownscaledCopyIsNotSmallerKeepTheirBytes() throws {
        // A heavily compressed mosaic: the 2048 px re-encode at quality 0.8 is several times larger.
        let photo = try mosaicJPEGData(width: 3_000, height: 2_000)
        let reencoded = try #require(StoredPhotoCompressor.downscaledJPEGData(photo))
        try #require(reencoded.count > photo.count)

        let name = try #require(FoodImageStore.shared.store(data: photo, for: UUID()))
        defer { FoodImageStore.shared.delete(filename: name) }
        StoredPhotoCompressor.newPhotoQueue.sync {}
        #expect(FoodImageStore.shared.load(filename: name) == photo)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoredPhotoCompressorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try photo.write(to: folder.appendingPathComponent("mosaic.jpg"))

        #expect(StoredPhotoCompressor.compressPhotos(in: folder) == StoredPhotoCompressor.Result())
        #expect(try Data(contentsOf: folder.appendingPathComponent("mosaic.jpg")) == photo)
    }

    @Test func legacyInlinePhotosMoveToDiskWithTheirBytesUnchanged() throws {
        let suite = "StoredPhotoCompressorTests.Legacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let photo = try jpegData(width: 3_000, height: 2_000)
        let entry = FoodEntry(
            name: "Legacy meal", calories: 500, protein: 20, carbs: 60, fat: 15,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            source: .snapFood, mealType: .dinner
        )
        // Rows from builds before FoodImageStore carried the JPEG inline as base64.
        var row = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        row["imageData"] = photo.base64EncodedString()
        defaults.set(try JSONSerialization.data(withJSONObject: [row]), forKey: FoodStore.storageKey)

        let store = FoodStore(observesExternalChanges: false, defaults: defaults)
        let filename = try #require(store.entries.first?.imageFilename)
        defer { FoodImageStore.shared.delete(filename: filename) }
        StoredPhotoCompressor.newPhotoQueue.sync {}

        #expect(FoodImageStore.shared.load(filename: filename) == photo)
    }

    @Test func compressionMessageReportsFailuresInsteadOfNothingToDo() {
        let nothingToDo = String(localized: "No photos needed compressing.")
        let unreadable = String(localized: "Some photos couldn’t be read and were left unchanged.")
        let failed = String(localized: "Some photos couldn’t be compressed and were left unchanged. Make sure your device has free space, then try again.")

        #expect(StorageSettingsSection.compressionMessage(for: .init()) == nothingToDo)
        #expect(StorageSettingsSection.compressionMessage(for: .init(unreadableCount: 1)) == unreadable)
        #expect(StorageSettingsSection.compressionMessage(for: .init(failedCount: 2)) == failed)
        let partial = StorageSettingsSection.compressionMessage(for: .init(compressedCount: 3, failedCount: 1, bytesSaved: 4_000_000))
        #expect(partial.hasSuffix(failed))
        #expect(!partial.contains(nothingToDo))
    }

    @Test func compressingExistingPhotosKeepsNamesAndSkipsSmallOrUnreadableFiles() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoredPhotoCompressorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let large = try jpegData(width: 4_000, height: 3_000, orientation: .down)
        let small = try jpegData(width: 1_200, height: 900)
        let broken = Data("not an image".utf8)
        try large.write(to: folder.appendingPathComponent("a-large.jpg"))
        try small.write(to: folder.appendingPathComponent("b-small.jpg"))
        try broken.write(to: folder.appendingPathComponent("c-broken.jpg"))
        var progress: [[Int]] = []

        let result = StoredPhotoCompressor.compressPhotos(in: folder) { done, total in progress.append([done, total]) }

        let compressed = try Data(contentsOf: folder.appendingPathComponent("a-large.jpg"))
        #expect(result.compressedCount == 1)
        #expect(result.unreadableCount == 1)
        #expect(result.failedCount == 0)
        #expect(result.bytesSaved == Int64(large.count - compressed.count))
        #expect(progress == [[1, 3], [2, 3], [3, 3]])
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["a-large.jpg", "b-small.jpg", "c-broken.jpg"])
        let info = try imageInfo(compressed)
        #expect(max(info.width, info.height) <= StoredPhotoCompressor.maxPixelSize)
        #expect(info.width > info.height)
        #expect(info.orientation == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent("b-small.jpg")) == small)
        #expect(try Data(contentsOf: folder.appendingPathComponent("c-broken.jpg")) == broken)

        // A second run finds nothing left to do.
        #expect(StoredPhotoCompressor.compressPhotos(in: folder).compressedCount == 0)
    }

    @Test func clearingTheThumbnailCacheNeverTouchesPhotos() async throws {
        let photo = try jpegData(width: 600, height: 400)
        let name = try #require(FoodImageStore.shared.store(data: photo, for: UUID()))
        defer { FoodImageStore.shared.delete(filename: name) }
        let thumbnailFolder = try #require(FoodImageStore.shared.thumbnailCacheFolderURL)
        #expect(FileManager.default.fileExists(atPath: thumbnailFolder.appendingPathComponent(name).path))

        await FoodImageStore.shared.clearThumbnailCache()

        #expect(!FileManager.default.fileExists(atPath: thumbnailFolder.appendingPathComponent(name).path))
        #expect(FoodImageStore.shared.load(filename: name) == photo)
        #expect(FoodImageStore.shared.loadThumbnail(filename: name) != nil)
    }

    @Test func directorySizeCountsFilesAndToleratesMissingFolders() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStorageUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 5_000).write(to: folder.appendingPathComponent("a.bin"))
        try Data(count: 7_000).write(to: folder.appendingPathComponent("nested/b.bin"))

        #expect(AppStorageUsage.directorySize(at: folder) >= 12_000)
        #expect(AppStorageUsage.directorySize(at: folder.appendingPathComponent("missing")) == 0)
        #expect(AppStorageUsage.directorySize(at: nil) == 0)
    }

    @Test func modelSizeCountsPartialAndHiddenDownloadFiles() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStorageUsageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let gemma = base.appendingPathComponent("Gemma4E2B", isDirectory: true)
        let whisper = base.appendingPathComponent("WhisperBase", isDirectory: true)
        let incomplete = whisper.appendingPathComponent("models/argmaxinc/whisperkit-coreml/.cache/huggingface/download", isDirectory: true)
        try FileManager.default.createDirectory(at: gemma, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        // A Gemma download in progress and a WhisperKit file still downloading.
        try Data(count: 50_000).write(to: gemma.appendingPathComponent("artifact.partial"))
        try Data(count: 30_000).write(to: incomplete.appendingPathComponent("weights.bin.etag.incomplete"))

        #expect(AppStorageUsage.directorySize(at: whisper) < 30_000)
        #expect(AppStorageUsage.modelBytes(in: [gemma, whisper]) >= 80_000)
        #expect(AppStorageUsage.modelBytes(in: [base.appendingPathComponent("missing")]) == 0)
        let manager = Gemma4LocalModelManager(rootDirectory: gemma, physicalMemoryBytes: 0)
        #expect(manager.storageDirectory == gemma)
    }

    // MARK: - Helpers

    /// Left half red, right half blue, encoded as JPEG with an EXIF orientation tag.
    private func jpegData(width: Int, height: Int, orientation: CGImagePropertyOrientation = .up) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyOrientation: orientation.rawValue
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// 16 px tiles of pseudo-random colors, encoded at the lowest JPEG quality.
    private func mosaicJPEGData(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextComponent() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat((seed >> 33) & 0xFF) / 255
        }
        for y in stride(from: 0, to: height, by: 16) {
            for x in stride(from: 0, to: width, by: 16) {
                context.setFillColor(red: nextComponent(), green: nextComponent(), blue: nextComponent(), alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 16, height: 16))
            }
        }
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.0] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func imageInfo(_ data: Data) throws -> (width: Int, height: Int, orientation: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let height = try #require((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (width, height, orientation)
    }
}
