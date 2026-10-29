import CryptoKit
import Foundation
import Testing
import UIKit
@testable import calorietracker

@MainActor
struct ExerciseVisualAssetResolverTests {
    private let jpegPaths = [
        "Barbell_Full_Squat_0.jpg",
        "Barbell_Full_Squat_1.jpg"
    ]

    @Test func manifestAcceptsThreeFourAndFiveFrameAtomicGenderSets() throws {
        for frameCount in 3...5 {
            let manifest = try makeManifest(frameCount: frameCount)
            let entry = try #require(manifest.entry(for: "Barbell_Full_Squat"))

            #expect(entry.frameCount == frameCount)
            #expect(entry.frames(for: .female) == frameNames(gender: "female", count: frameCount))
            #expect(entry.frames(for: .male) == frameNames(gender: "male", count: frameCount))
            #expect(entry.frames(for: .other) == frameNames(gender: "male", count: frameCount))
        }
    }

    @Test func completeSVGSetIsPreferredAndUsesManifestRepresentativeFrame() throws {
        let svgNames = frameNames(gender: "female", count: 4)
        let asset = FreeExerciseDBAssetResolver.preferredVisualAsset(
            for: jpegPaths,
            gender: .female,
            manifest: try makeManifest(frameCount: 4, representativeFrameIndex: 2),
            resolveJPEGURL: jpegResolver
        )

        #expect(asset.format == .svg)
        #expect(asset.frames == svgNames.map { authoredFrame($0, format: .svg) })
        #expect(asset.representativeFrameIndex == 2)
    }

    @Test func missingOppositeGenderSetFallsBackToOriginalJPEGSequence() throws {
        let manifest = try makeManifest(frameCount: 4, includeFemaleFrames: false)
        let asset = FreeExerciseDBAssetResolver.preferredVisualAsset(
            for: jpegPaths,
            gender: .male,
            manifest: manifest,
            resolveJPEGURL: jpegResolver
        )

        #expect(asset.format == .jpeg)
        #expect(asset.frames == jpegPaths.map { .file(resolvedURL(for: $0)) })
        #expect(asset.representativeFrameIndex == 0)
    }

    @Test func manifestSupportsVersionedPNGFrames() throws {
        let femaleFrames = v2FrameNames(gender: "female")
        let asset = FreeExerciseDBAssetResolver.preferredVisualAsset(
            for: jpegPaths,
            gender: .female,
            manifest: try makeManifest(
                frameCount: 4,
                representativeFrameIndex: 2,
                format: "png",
                maleFrames: v2FrameNames(gender: "male"),
                femaleFrames: femaleFrames
            ),
            resolveJPEGURL: jpegResolver
        )

        #expect(asset.format == .png)
        #expect(asset.frames == femaleFrames.map { authoredFrame($0, format: .png) })
        #expect(asset.representativeFrameIndex == 2)
    }

    @Test func manifestFrameDigestsAreParsedAndMalformedOnesIgnored() throws {
        let femaleFrames = v2FrameNames(gender: "female")
        let maleFrames = v2FrameNames(gender: "male")
        let manifest = try makeManifest(
            frameCount: 4,
            representativeFrameIndex: 2,
            format: "png",
            maleFrames: maleFrames,
            femaleFrames: femaleFrames,
            maleFrameDigests: ["0123456789abcdef", "ABCDEF0123456789", "not-a-digest", "fedcba9876543210"],
            femaleFrameDigests: ["0123456789abcdef"] // wrong length → ignored
        )
        let entry = try #require(manifest.entry(for: "Barbell_Full_Squat"))

        #expect(entry.maleFrameDigests == ["0123456789abcdef", "abcdef0123456789", nil, "fedcba9876543210"])
        #expect(entry.femaleFrameDigests == [nil, nil, nil, nil])

        let male = FreeExerciseDBAssetResolver.preferredVisualAsset(
            for: jpegPaths,
            gender: .male,
            manifest: manifest,
            resolveJPEGURL: jpegResolver
        )
        #expect(male.frames[1] == .authored(ExerciseAuthoredFrame(name: maleFrames[1], digest: "abcdef0123456789", format: .png)))
        #expect(male.frames[2] == .authored(ExerciseAuthoredFrame(name: maleFrames[2], digest: nil, format: .png)))
    }

    @Test func invalidTwoOrSixFrameSetsFallBackToJPEG() throws {
        for frameCount in [2, 6] {
            let asset = FreeExerciseDBAssetResolver.preferredVisualAsset(
                for: jpegPaths,
                gender: .male,
                manifest: try makeManifest(frameCount: frameCount),
                resolveJPEGURL: jpegResolver
            )

            #expect(asset.format == .jpeg)
            #expect(asset.frames == jpegPaths.map { .file(resolvedURL(for: $0)) })
        }
    }

    @Test func exerciseIDIsInferredFromNestedJPEGFilename() throws {
        let nestedJPEGPaths = jpegPaths.map { "FreeExerciseDB/images/\($0)" }
        let svgNames = frameNames(gender: "male", count: 4)
        let asset = FreeExerciseDBAssetResolver.preferredVisualAsset(
            for: nestedJPEGPaths,
            gender: .other,
            manifest: try makeManifest(frameCount: 4),
            resolveJPEGURL: { _ in nil }
        )

        #expect(asset.format == .svg)
        #expect(asset.frames == svgNames.map { authoredFrame($0, format: .svg) })
    }

    @Test func bundledManifestDescribesV2PNGsWithoutBundlingTheCorpus() throws {
        let manifestData = try #require(NSDataAsset(name: "ExerciseVisualManifest")?.data)
        let manifest = try ExerciseVisualManifest(data: manifestData)
        let entry = try #require(manifest.entry(for: "Barbell_Full_Squat"))
        #expect(entry.frameCount == 4)
        #expect(entry.maleFrameDigests.allSatisfy { $0 != nil })
        #expect(entry.femaleFrameDigests.allSatisfy { $0 != nil })

        for gender in [Gender.male, .female] {
            let asset = FreeExerciseDBAssetResolver.preferredVisualAsset(
                for: jpegPaths,
                gender: gender
            )

            #expect(asset.format == .png)
            #expect(asset.frames.count == 4)
            for frame in asset.frames {
                guard case .authored(let authored) = frame else {
                    Issue.record("expected an authored frame, got \(frame)")
                    continue
                }
                #expect(authored.digest != nil)
                // The 1.2 GB corpus must never be compiled into the asset catalog again.
                #expect(UIImage(named: authored.name) == nil)
                // Barbell_Full_Squat is in the Debug sample pack; when the build phase bundled
                // it, the copy must be byte-identical to the canonical corpus.
                if let bundled = WorkoutFrameStore.bundledURL(for: authored) {
                    #expect(bundled.lastPathComponent == "\(authored.name).png")
                    let bytes = try Data(contentsOf: bundled)
                    #expect(WorkoutFrameStore.looksLikePNG(bytes))
                    #expect(WorkoutFrameStore.data(bytes, matchesDigest: authored.digest))
                }
            }
        }
    }

    @Test func frameDownloadsDefaultToTheProductionCDN() {
        #expect(WorkoutFrameStore.defaultBaseURL.absoluteString == "https://assets.fud-ai.app/workout-vectors/v2")
        // A developer scheme may set the launch argument; only assert the default state.
        guard UserDefaults.standard.string(forKey: WorkoutFrameStore.baseURLOverrideKey) == nil else { return }
        #expect(WorkoutFrameStore.configuredBaseURL() == WorkoutFrameStore.defaultBaseURL)
    }

    @Test func frameStoreNamingRules() {
        let frame = ExerciseAuthoredFrame(name: "Barbell_Full_Squat_female_v2_2", digest: "0123456789ABCDEF", format: .png)
        #expect(WorkoutFrameStore.cacheFileName(for: frame) == "Barbell_Full_Squat_female_v2_2.0123456789abcdef.png")
        #expect(
            WorkoutFrameStore.remoteURL(baseURL: URL(string: "https://assets.fud-ai.app/workout-vectors/v2"), frame: frame)?.absoluteString
                == "https://assets.fud-ai.app/workout-vectors/v2/Barbell_Full_Squat_female_v2_2.png?v=0123456789abcdef"
        )
        let undigested = ExerciseAuthoredFrame(name: "Ab_Roller_male_v2_0", digest: "zz", format: .png)
        #expect(WorkoutFrameStore.cacheFileName(for: undigested) == "Ab_Roller_male_v2_0.nodigest.png")
        #expect(
            WorkoutFrameStore.remoteURL(baseURL: URL(string: "http://localhost:8765/"), frame: undigested)?.absoluteString
                == "http://localhost:8765/Ab_Roller_male_v2_0.png"
        )
        #expect(WorkoutFrameStore.remoteURL(baseURL: nil, frame: frame) == nil)
        #expect(WorkoutFrameStore.remoteURL(baseURL: URL(string: "ftp://example.com"), frame: frame) == nil)

        let bytes = Data("frame-bytes".utf8)
        let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(WorkoutFrameStore.data(bytes, matchesDigest: String(sha256.prefix(16))))
        #expect(WorkoutFrameStore.data(bytes, matchesDigest: nil))
        #expect(!WorkoutFrameStore.data(bytes, matchesDigest: "0000000000000000"))
        #expect(WorkoutFrameStore.looksLikePNG(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])))
        #expect(!WorkoutFrameStore.looksLikePNG(Data("<svg/>".utf8)))
    }

    @Test func frameStoreServesCachedFileWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workout-frame-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // No base URL: the store must never attempt a download. The name is deliberately
        // not part of the bundled corpus so only the cache can satisfy it.
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])
        let digest = String(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(16))
        let store = WorkoutFrameStore(baseURL: nil, cacheDirectory: directory)
        let frame = ExerciseAuthoredFrame(name: "Not_A_Real_Exercise_male_v2_1", digest: digest, format: .png)

        #expect(WorkoutFrameStore.bundledURL(for: frame) == nil)
        #expect(await store.localURL(for: frame) == nil)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cached = store.cacheFileURL(for: frame)
        try bytes.write(to: cached)
        #expect(await store.offlineURL(for: frame) == cached)
        #expect(await store.localURL(for: frame) == cached)

        await store.clearCache()
        #expect(await store.offlineURL(for: frame) == nil)
    }

    @Test func frameStoreDiscardsCorruptCacheEntries() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workout-frame-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = WorkoutFrameStore(baseURL: nil, cacheDirectory: directory)

        let manifestData = try #require(NSDataAsset(name: "ExerciseVisualManifest")?.data)
        let manifest = try ExerciseVisualManifest(data: manifestData)
        let entry = try #require(manifest.entry(for: "Barbell_Full_Squat"))
        let frame = entry.authoredFrames(for: .male)[2]
        #expect(frame.digest != nil)
        // Barbell_Full_Squat is in the Debug sample pack, so a Debug test bundle serves it
        // from the bundle once the cache entry is rejected; a release-parity bundle has no
        // frames and falls through to nil (no base URL → no download).
        let bundled = WorkoutFrameStore.bundledURL(for: frame)
        let cached = store.cacheFileURL(for: frame)

        // A valid PNG header whose bytes do not match the manifest digest (e.g. a torn write
        // or a leftover from an older revision) must be discarded, never served.
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0]).write(to: cached)
        #expect(await store.offlineURL(for: frame) == bundled)
        #expect(!FileManager.default.fileExists(atPath: cached.path))

        // Not a PNG at all (e.g. a captive-portal HTML page written by an older build).
        try Data("<html>offline</html>".utf8).write(to: cached)
        #expect(await store.localURL(for: frame) == bundled)
        #expect(!FileManager.default.fileExists(atPath: cached.path))

        // Empty file.
        try Data().write(to: cached)
        #expect(await store.offlineURL(for: frame) == bundled)
        #expect(!FileManager.default.fileExists(atPath: cached.path))

        // A byte-exact copy of the frame verifies and is served from the cache.
        let canonical = try Data(contentsOf: try #require(bundled ?? canonicalCorpusURL(for: frame)))
        #expect(WorkoutFrameStore.isValidFrameData(canonical, for: frame))
        try canonical.write(to: cached)
        #expect(await store.offlineURL(for: frame) == cached)
        #expect(FileManager.default.fileExists(atPath: cached.path))
    }

    @Test func staticThumbnailRetryBackoffMatchesAndroid() {
        // 15 s, 30 s, then capped at the store's 60 s failure-memoization window.
        #expect(ExerciseFrameRetryPolicy.delay(attempt: 0) == .seconds(15))
        #expect(ExerciseFrameRetryPolicy.delay(attempt: 1) == .seconds(30))
        #expect(ExerciseFrameRetryPolicy.delay(attempt: 2) == .seconds(60))
        #expect(ExerciseFrameRetryPolicy.delay(attempt: 9) == .seconds(60))
        #expect(ExerciseFrameRetryPolicy.delay(attempt: -1) == .seconds(15))
    }

    @Test func frameDataValidationMatchesAndroidRules() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])
        let digest = String(SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined().prefix(16))
        let frame = ExerciseAuthoredFrame(name: "Ab_Roller_male_v2_0", digest: digest, format: .png)

        #expect(WorkoutFrameStore.isValidFrameData(png, for: frame))
        #expect(!WorkoutFrameStore.isValidFrameData(Data(), for: frame))
        #expect(!WorkoutFrameStore.isValidFrameData(Data("<svg/>".utf8), for: frame))
        #expect(!WorkoutFrameStore.isValidFrameData(png, for: ExerciseAuthoredFrame(name: frame.name, digest: "0000000000000000", format: .png)))
        // Without a manifest digest only the format is checked.
        #expect(WorkoutFrameStore.isValidFrameData(png, for: ExerciseAuthoredFrame(name: frame.name, digest: nil, format: .png)))
        #expect(!WorkoutFrameStore.isValidFrameData(Data(repeating: 0x89, count: 4 * 1_024 * 1_024 + 1), for: ExerciseAuthoredFrame(name: frame.name, digest: nil, format: .png)))
    }

    /// The corpus must never ship: at most the Debug sample pack may be in the bundle, and
    /// every bundled frame must be a manifest frame that is byte-identical to the corpus.
    @Test func bundleNeverContainsTheFrameCorpus() throws {
        let manifestData = try #require(NSDataAsset(name: "ExerciseVisualManifest")?.data)
        let document = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let exercises = try #require(document["exercises"] as? [[String: Any]])
        #expect(exercises.count == 875)
        var manifestFrames: [String: String?] = [:]
        for exercise in exercises {
            for (namesKey, digestsKey) in [("maleFrames", "maleFrameDigests"), ("femaleFrames", "femaleFrameDigests")] {
                let names = try #require(exercise[namesKey] as? [String])
                let digests = exercise[digestsKey] as? [String?] ?? Array(repeating: nil, count: names.count)
                for (name, digest) in zip(names, digests) {
                    manifestFrames["\(name).png"] = digest
                }
            }
        }
        #expect(manifestFrames.count == 7_000)

        // A frame outside the sample pack must never be bundled, in any configuration.
        let outsideSample = ExerciseAuthoredFrame(name: "Ab_Roller_male_v2_0", digest: nil, format: .png)
        #expect(manifestFrames["Ab_Roller_male_v2_0.png"] != nil)
        #expect(WorkoutFrameStore.bundledURL(for: outsideSample) == nil)

        let folder = Bundle.main.url(forResource: WorkoutFrameStore.bundledFrameDirectory, withExtension: nil)
        #if DEBUG
        // Debug builds may carry the sample pack (12 exercises × 2 genders × 4 frames) or,
        // with WORKOUT_VECTORS=none, nothing at all.
        let maximumBundledFrames = 12 * 2 * 4
        #else
        #expect(folder == nil, "release builds must bundle no workout frames")
        let maximumBundledFrames = 0
        #endif
        guard let folder else { return }

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.count <= maximumBundledFrames, "bundled \(names.count) frames; only the sample pack may ship in Debug")
        let unexpected = names.filter { !($0.contains("_v2_") && $0.hasSuffix(".png")) }
        #expect(unexpected.isEmpty, "tooling files leaked into the bundle: \(unexpected)")
        for name in names {
            let digest = try #require(manifestFrames[name], "bundled frame is not in the manifest: \(name)")
            let bytes = try Data(contentsOf: folder.appendingPathComponent(name))
            #expect(WorkoutFrameStore.looksLikePNG(bytes))
            #expect(WorkoutFrameStore.data(bytes, matchesDigest: digest), "bundled frame differs from the corpus: \(name)")
        }
    }

    /// `shared/workout-vectors/<name>.png` in the checkout, when the tests run next to it.
    private func canonicalCorpusURL(for frame: ExerciseAuthoredFrame) -> URL? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // calorietrackerTests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("shared/workout-vectors/\(frame.name).\(frame.fileExtension)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func authoredFrame(_ name: String, format: ExerciseVisualAsset.Format) -> ExerciseVisualFrame {
        .authored(ExerciseAuthoredFrame(name: name, digest: nil, format: format))
    }

    private func makeManifest(
        frameCount: Int,
        representativeFrameIndex: Int = 1,
        format: String? = nil,
        maleFrames: [String]? = nil,
        femaleFrames: [String]? = nil,
        maleFrameDigests: [String]? = nil,
        femaleFrameDigests: [String]? = nil,
        includeMaleFrames: Bool = true,
        includeFemaleFrames: Bool = true
    ) throws -> ExerciseVisualManifest {
        var entry: [String: Any] = [
            "exerciseId": "Barbell_Full_Squat",
            "frameCount": frameCount,
            "representativeFrameIndex": representativeFrameIndex,
        ]
        if let format {
            entry["format"] = format
        }
        if includeMaleFrames {
            entry["maleFrames"] = maleFrames ?? frameNames(gender: "male", count: frameCount)
        }
        if includeFemaleFrames {
            entry["femaleFrames"] = femaleFrames ?? frameNames(gender: "female", count: frameCount)
        }
        if let maleFrameDigests {
            entry["maleFrameDigests"] = maleFrameDigests
        }
        if let femaleFrameDigests {
            entry["femaleFrameDigests"] = femaleFrameDigests
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "exercises": [entry],
        ])
        return try ExerciseVisualManifest(data: data)
    }

    private func frameNames(gender: String, count: Int) -> [String] {
        guard count > 0 else { return [] }
        return (0..<count).map { "Barbell_Full_Squat_\(gender)_\($0)" }
    }

    private func v2FrameNames(gender: String) -> [String] {
        (0..<4).map { "Barbell_Full_Squat_\(gender)_v2_\($0)" }
    }

    private var jpegResolver: (String) -> URL? {
        { resolvedURL(for: $0) }
    }

    private func resolvedURL(for path: String) -> URL {
        URL(fileURLWithPath: "/resolved/\(path)")
    }
}
