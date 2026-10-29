import CryptoKit
import Foundation
import os

/// Delivers authored workout frames without shipping the 1.2 GB corpus inside the IPA.
///
/// Resolution order for a frame:
/// 1. on-device cache (`Caches/WorkoutVectors/v2/<name>.<digest>.png`) — served only after
///    the file verifies against the manifest (size, PNG signature, digest); anything else
///    is deleted so a torn write can never pin the UI to its placeholder,
/// 2. the bundled `workout-vectors` folder: Debug builds carry the small sample pack
///    (`ios/scripts/copy_workout_frames.sh`); release builds bundle no frames at all,
/// 3. download from the workout-vector CDN (`<base>/<name>.png?v=<digest>`), size-capped,
///    verified against the manifest digest, written atomically and stored in the cache.
///
/// Anything that fails resolves to nil and the UI keeps its placeholder, which is the
/// behaviour the app had before authored frames existed. Failures are remembered briefly
/// so an offline user does not retry every frame on every animation tick, and the cache is
/// trimmed back to ~192 MB once it passes 256 MB.
actor WorkoutFrameStore {
    nonisolated static let shared = WorkoutFrameStore()

    /// Public CDN prefix (R2 bucket `fud-ai-assets` behind a custom domain; see
    /// shared/workout-vectors/README.md). Store builds always use this.
    nonisolated static let defaultBaseURL = URL(string: "https://assets.fud-ai.app/workout-vectors/v2")!
    /// Debug-only override, e.g. launch argument `-WorkoutVectorsBaseURL http://localhost:8765`
    /// while `python3 -m http.server -d shared/workout-vectors 8765` serves the corpus;
    /// `-WorkoutVectorsBaseURL none` disables downloads to test offline behaviour.
    nonisolated static let baseURLOverrideKey = "WorkoutVectorsBaseURL"
    /// Bundle subdirectory the "Copy Workout Frames" build phase copies the Debug sample pack to.
    nonisolated static let bundledFrameDirectory = "workout-vectors"

    nonisolated private static let failureRetryInterval: TimeInterval = 60
    nonisolated private static let maxFrameBytes = 4 * 1_024 * 1_024
    nonisolated private static let maxCacheBytes = 256 * 1_024 * 1_024
    nonisolated private static let trimTargetBytes = 192 * 1_024 * 1_024
    nonisolated private static let trimEveryDownloads = 16
    nonisolated private static let logger = Logger(subsystem: "com.apoorvdarshan.calorietracker", category: "WorkoutFrameStore")

    private let baseURL: URL?
    private let cacheDirectory: URL
    private let session: URLSession
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private var recentFailures: [String: Date] = [:]
    /// Cache file names already verified against the manifest in this process, so a
    /// frame is hashed once rather than on every animation tick.
    private var verifiedCacheFiles: Set<String> = []
    private var downloadsSinceTrim = 0

    init(
        baseURL: URL? = WorkoutFrameStore.configuredBaseURL(),
        cacheDirectory: URL? = nil,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
        self.session = session
    }

    // MARK: - Configuration

    /// The production CDN, unless a Debug launch argument overrides it (`none` disables downloads).
    nonisolated static func configuredBaseURL() -> URL? {
        #if DEBUG
        if
            let override = UserDefaults.standard.string(forKey: baseURLOverrideKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return override.lowercased() == "none" ? nil : URL(string: override)
        }
        #endif
        return defaultBaseURL
    }

    nonisolated static func defaultCacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("WorkoutVectors/v2", isDirectory: true)
    }

    // MARK: - Naming rules (shared with tests)

    nonisolated static func normalizedDigest(_ digest: String?) -> String? {
        guard let digest = digest?.lowercased(), (8...64).contains(digest.count) else { return nil }
        let hex = digest.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        return hex ? digest : nil
    }

    nonisolated static func cacheFileName(for frame: ExerciseAuthoredFrame) -> String {
        "\(frame.name).\(normalizedDigest(frame.digest) ?? "nodigest").\(frame.fileExtension)"
    }

    nonisolated static func remoteURL(baseURL: URL?, frame: ExerciseAuthoredFrame) -> URL? {
        guard
            let baseURL,
            let scheme = baseURL.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            var components = URLComponents(
                url: baseURL.appendingPathComponent("\(frame.name).\(frame.fileExtension)"),
                resolvingAgainstBaseURL: false
            )
        else {
            return nil
        }
        if let digest = normalizedDigest(frame.digest) {
            components.queryItems = [URLQueryItem(name: "v", value: digest)]
        }
        return components.url
    }

    nonisolated static func data(_ data: Data, matchesDigest digest: String?) -> Bool {
        guard let expected = normalizedDigest(digest) else { return true }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual.hasPrefix(expected)
    }

    nonisolated static func looksLikePNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return data.count > signature.count && Array(data.prefix(signature.count)) == signature
    }

    /// Whether `data` is acceptable as the cached/downloaded bytes of `frame`: non-empty,
    /// within the size cap, a PNG when the manifest says PNG, and matching the manifest digest.
    nonisolated static func isValidFrameData(_ data: Data, for frame: ExerciseAuthoredFrame) -> Bool {
        guard !data.isEmpty, data.count <= maxFrameBytes else { return false }
        if frame.format == .png, !looksLikePNG(data) { return false }
        return self.data(data, matchesDigest: frame.digest)
    }

    // MARK: - Lookup

    nonisolated func cacheFileURL(for frame: ExerciseAuthoredFrame) -> URL {
        cacheDirectory.appendingPathComponent(Self.cacheFileName(for: frame), isDirectory: false)
    }

    /// The frame inside the app bundle (Debug sample pack only; release bundles none).
    /// Bundled frames are trusted as-is: the bundle is code-signed and the build phase
    /// copies the canonical corpus byte-for-byte, so the manifest digest is only
    /// re-checked for cached/downloaded files.
    nonisolated static func bundledURL(for frame: ExerciseAuthoredFrame, in bundle: Bundle = .main) -> URL? {
        bundle.url(
            forResource: frame.name,
            withExtension: frame.fileExtension,
            subdirectory: bundledFrameDirectory
        ) ?? bundle.url(forResource: frame.name, withExtension: frame.fileExtension)
    }

    /// Frame file that can be shown without touching the network, if any: a verified cache
    /// entry first, otherwise a bundled (Debug sample) frame.
    func offlineURL(for frame: ExerciseAuthoredFrame) -> URL? {
        verifiedCachedURL(for: frame) ?? Self.bundledURL(for: frame)
    }

    /// The cached frame only if its bytes verify against the manifest. A corrupt or stale
    /// entry (a torn write, a file the system half-purged) is deleted so the next request
    /// re-downloads it instead of failing to decode forever.
    private func verifiedCachedURL(for frame: ExerciseAuthoredFrame) -> URL? {
        let cached = cacheFileURL(for: frame)
        let name = cached.lastPathComponent
        guard FileManager.default.fileExists(atPath: cached.path) else {
            verifiedCacheFiles.remove(name)
            return nil
        }
        if verifiedCacheFiles.contains(name) {
            return cached
        }
        let size = (try? cached.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if
            (1...Self.maxFrameBytes).contains(size),
            let data = try? Data(contentsOf: cached),
            Self.isValidFrameData(data, for: frame)
        {
            verifiedCacheFiles.insert(name)
            return cached
        }
        Self.logger.notice("discarding invalid cached workout frame: \(name, privacy: .public)")
        try? FileManager.default.removeItem(at: cached)
        return nil
    }

    /// Local file URL for `frame` (cache → bundled debug sample → CDN download). Nil when unavailable.
    func localURL(for frame: ExerciseAuthoredFrame) async -> URL? {
        if let url = offlineURL(for: frame) {
            return url
        }
        guard let remote = Self.remoteURL(baseURL: baseURL, frame: frame) else { return nil }
        if let failedAt = recentFailures[frame.name], Date().timeIntervalSince(failedAt) < Self.failureRetryInterval {
            return nil
        }
        if let task = inFlight[frame.name] {
            return await task.value
        }
        let task = Task<URL?, Never> { await self.download(frame, from: remote) }
        inFlight[frame.name] = task
        let result = await task.value
        inFlight[frame.name] = nil
        return result
    }

    /// Deletes every cached frame. Frames are re-downloadable, so this loses nothing.
    func clearCache() {
        verifiedCacheFiles.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    // MARK: - Download

    private func download(_ frame: ExerciseAuthoredFrame, from remote: URL) async -> URL? {
        let target = cacheFileURL(for: frame)
        do {
            var request = URLRequest(url: remote)
            request.setValue(frame.format == .svg ? "image/svg+xml" : "image/png", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw FrameError.badResponse
            }
            let data = try await Self.readBounded(bytes, declaredLength: http.expectedContentLength)
            guard frame.format != .png || Self.looksLikePNG(data) else { throw FrameError.notAnImage }
            guard Self.data(data, matchesDigest: frame.digest) else { throw FrameError.digestMismatch }

            let fileManager = FileManager.default
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let partial = target.appendingPathExtension("part")
            try data.write(to: partial, options: .atomic)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.moveItem(at: partial, to: target)
            verifiedCacheFiles.insert(target.lastPathComponent)
            removeStaleRevisions(of: frame, keeping: target.lastPathComponent)
            recentFailures[frame.name] = nil
            downloadsSinceTrim += 1
            if downloadsSinceTrim % Self.trimEveryDownloads == 0 {
                trimCacheIfNeeded()
            }
            return target
        } catch {
            try? FileManager.default.removeItem(at: target.appendingPathExtension("part"))
            recentFailures[frame.name] = Date()
            Self.logger.notice("workout frame download failed: \(frame.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Reads at most `maxFrameBytes`, aborting as soon as the stream exceeds the cap so a
    /// misconfigured or hostile origin can never buffer an unbounded response in memory.
    /// The declared length is an early rejection only: it may be absent (chunked) or wrong.
    nonisolated private static func readBounded(_ bytes: URLSession.AsyncBytes, declaredLength: Int64) async throws -> Data {
        guard declaredLength <= Int64(maxFrameBytes) else { throw FrameError.tooLarge }
        var data = Data()
        data.reserveCapacity(declaredLength > 0 ? Int(declaredLength) : 256 * 1_024)
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= maxFrameBytes else { throw FrameError.tooLarge }
        }
        return data
    }

    private func removeStaleRevisions(of frame: ExerciseAuthoredFrame, keeping keep: String) {
        let prefix = "\(frame.name)."
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path) else { return }
        for name in names where name.hasPrefix(prefix) && name != keep && !name.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(name))
        }
    }

    /// Keeps the frame cache bounded; the system may also purge Caches on its own.
    private func trimCacheIfNeeded() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        var entries: [(url: URL, size: Int, modified: Date)] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > Self.maxCacheBytes else { return }
        entries.sort { $0.modified < $1.modified }
        for entry in entries {
            guard total > Self.trimTargetBytes else { break }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }

    nonisolated private enum FrameError: Error {
        case badResponse
        case tooLarge
        case notAnImage
        case digestMismatch
    }
}
