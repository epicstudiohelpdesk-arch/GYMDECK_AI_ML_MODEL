import Foundation
import LiteRTLM
import Testing
@testable import calorietracker

@MainActor
struct Gemma4LocalModelManagerTests {
    @Test func approvedArtifactMetadataIsImmutable() {
        #expect(Gemma4LocalModelManager.modelID == "gemma-4-E2B-it")
        #expect(Gemma4LocalModelManager.artifactFilename == "gemma-4-E2B-it.litertlm")
        #expect(Gemma4LocalModelManager.sourceRevision == "6b78abd019e61a1ca4cbe3b212d2c9ce8ff38a94")
        #expect(Gemma4LocalModelManager.artifactByteCount == 2_588_147_712)
        #expect(Gemma4LocalModelManager.artifactSHA256 == "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c")
        #expect(Gemma4LocalModelManager.artifactURL.absoluteString.contains(Gemma4LocalModelManager.sourceRevision))
        #expect(Gemma4LocalModelManager.sourceURL.absoluteString.contains(Gemma4LocalModelManager.sourceRevision))
        #expect(Gemma4LocalModelManager.licenseURL.host == "ai.google.dev")
    }

    @Test func contextWindowMatchesStableMobileLimit() {
        #expect(Gemma4LocalModelManager.maxContextTokens == 4_096)
    }

    @Test func iosVisionEncoderUsesCPUWhileTextKeepsRequestedBackend() throws {
        let gpuConfig = try Gemma4LocalModelManager.engineConfig(
            modelPath: "/model.litertlm",
            backend: .gpu,
            cacheDir: "/cache"
        )
        let cpuConfig = try Gemma4LocalModelManager.engineConfig(
            modelPath: "/model.litertlm",
            backend: .cpu(threadCount: 2),
            cacheDir: "/cache"
        )

        #expect(gpuConfig.backend == .gpu)
        #expect(gpuConfig.visionBackend == .cpu(threadCount: 4))
        #expect(cpuConfig.backend == .cpu(threadCount: 2))
        #expect(cpuConfig.visionBackend == .cpu(threadCount: 4))
    }

    @Test func eligibilityUsesMarketedMemoryClass() {
        let gib: UInt64 = 1_024 * 1_024 * 1_024

        #expect(Gemma4LocalModelManager.memoryClassGB(physicalMemoryBytes: 0) == 0)
        #expect(Gemma4LocalModelManager.memoryClassGB(physicalMemoryBytes: 7 * gib) == 7)
        #expect(Gemma4LocalModelManager.memoryClassGB(physicalMemoryBytes: 7 * gib + 1) == 8)
        #expect(!Gemma4LocalModelManager.isEligible(physicalMemoryBytes: 7 * gib))
        #expect(Gemma4LocalModelManager.isEligible(physicalMemoryBytes: 7 * gib + 1))
        #expect(Gemma4LocalModelManager.isEligible(physicalMemoryBytes: 8 * gib))
    }

    @Test func storageCheckIncludesInstallationHeadroom() {
        let required = Gemma4LocalModelManager.artifactByteCount
            + Gemma4LocalModelManager.installationHeadroomBytes
        #expect(!Gemma4LocalModelManager.hasRequiredStorage(availableBytes: required - 1))
        #expect(Gemma4LocalModelManager.hasRequiredStorage(availableBytes: required))
    }

    @Test func storageCheckCountsBytesKeptForResume() {
        // A resume only needs room for the rest of the artifact, not the whole 2.59 GB again.
        let kept: Int64 = 2_000_000_000
        let required = Gemma4LocalModelManager.artifactByteCount - kept
            + Gemma4LocalModelManager.installationHeadroomBytes

        #expect(Gemma4LocalModelManager.requiredStorageBytes(keptBytes: kept) == required)
        #expect(!Gemma4LocalModelManager.hasRequiredStorage(availableBytes: required - 1, keptBytes: kept))
        #expect(Gemma4LocalModelManager.hasRequiredStorage(availableBytes: required, keptBytes: kept))
        #expect(
            Gemma4LocalModelManager.requiredStorageBytes(keptBytes: .max)
                == Gemma4LocalModelManager.installationHeadroomBytes
        )
    }

    @Test func verificationStreamsExactBytesAndSHA256() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.bin")
        try Data("abc".utf8).write(to: file)

        let verification = try Gemma4LocalModelManager.verifyArtifact(
            at: file,
            chunkSize: 2
        )

        #expect(verification.byteCount == 3)
        #expect(verification.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func installRequiresBothExactSizeAndVerifiedMarker() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model.litertlm")
        let marker = root.appendingPathComponent("verified.sha256")
        try Data([0x01, 0x02, 0x03]).write(to: model)

        #expect(!Gemma4LocalModelManager.hasVerifiedInstall(
            modelURL: model,
            verificationMarkerURL: marker,
            expectedByteCount: 3,
            expectedSHA256: "approved",
            fileManager: .default
        ))

        try Data("wrong".utf8).write(to: marker)
        #expect(!Gemma4LocalModelManager.hasVerifiedInstall(
            modelURL: model,
            verificationMarkerURL: marker,
            expectedByteCount: 3,
            expectedSHA256: "approved",
            fileManager: .default
        ))

        try Data("approved".utf8).write(to: marker)
        #expect(Gemma4LocalModelManager.hasVerifiedInstall(
            modelURL: model,
            verificationMarkerURL: marker,
            expectedByteCount: 3,
            expectedSHA256: "approved",
            fileManager: .default
        ))
    }

    @Test func providerSelectionAlsoRequiresSuccessfulRuntimeMarker() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model.litertlm")
        let verificationMarker = root.appendingPathComponent("verified.sha256")
        let preparedMarker = root.appendingPathComponent("prepared.version")
        try Data([0x01, 0x02, 0x03]).write(to: model)
        try Data("approved".utf8).write(to: verificationMarker)

        #expect(!Gemma4LocalModelManager.hasPreparedInstall(
            modelURL: model,
            verificationMarkerURL: verificationMarker,
            preparedMarkerURL: preparedMarker,
            expectedByteCount: 3,
            expectedSHA256: "approved",
            fileManager: .default
        ))

        try Data("wrong-runtime".utf8).write(to: preparedMarker)
        #expect(!Gemma4LocalModelManager.hasPreparedInstall(
            modelURL: model,
            verificationMarkerURL: verificationMarker,
            preparedMarkerURL: preparedMarker,
            expectedByteCount: 3,
            expectedSHA256: "approved",
            fileManager: .default
        ))

        try Data(Gemma4LocalModelManager.preparedMarkerContents.utf8).write(to: preparedMarker)
        #expect(Gemma4LocalModelManager.hasPreparedInstall(
            modelURL: model,
            verificationMarkerURL: verificationMarker,
            preparedMarkerURL: preparedMarker,
            expectedByteCount: 3,
            expectedSHA256: "approved",
            fileManager: .default
        ))
    }

    @Test func deletionRemovesOnlyTheDedicatedModelRoot() throws {
        let parent = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let modelRoot = parent.appendingPathComponent("Gemma4E2B", isDirectory: true)
        let sibling = parent.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        try Data([0x01]).write(to: modelRoot.appendingPathComponent("partial.bin"))
        try Data([0x02]).write(to: sibling)

        let manager = Gemma4LocalModelManager(
            rootDirectory: modelRoot,
            physicalMemoryBytes: Gemma4LocalModelManager.minimumPhysicalMemoryBytes
        )
        #expect(manager.hasStoredData)

        try manager.delete()

        #expect(!FileManager.default.fileExists(atPath: modelRoot.path))
        #expect(FileManager.default.fileExists(atPath: sibling.path))
        #expect(manager.state == .notDownloaded)
    }

    @Test func cancellingOutsideAnActiveDownloadNeverDeletesStoredData() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storedFile = root.appendingPathComponent("keep.partial")
        try Data([0x01]).write(to: storedFile)
        let manager = Gemma4LocalModelManager(
            rootDirectory: root,
            physicalMemoryBytes: Gemma4LocalModelManager.minimumPhysicalMemoryBytes
        )

        manager.cancelDownload()

        #expect(FileManager.default.fileExists(atPath: storedFile.path))
        #expect(manager.hasStoredData)
    }

    @Test func onlyAttemptsWithoutLastingProgressSpendTheRetryBudget() {
        var retry = GemmaDownloadRetryState(delays: [1, 2])
        let timeout = URLError(.timedOut)

        #expect(retry.recordFailure(timeout, lastingProgressBytes: 0) == .retry(after: 1))
        #expect(retry.recordFailure(timeout, lastingProgressBytes: 0) == .retry(after: 2))
        #expect(retry.recordFailure(timeout, lastingProgressBytes: 512) == .retry(after: 1))
        #expect(retry.recordFailure(timeout, lastingProgressBytes: 0) == .retry(after: 2))
        #expect(retry.recordFailure(timeout, lastingProgressBytes: 0) == .fail)
    }

    @Test func restartThatEndsBelowTheOldPartialSpendsTheRetryBudget() {
        // A server that ignores Range replaces the partial; dropping before the old length leaves
        // less than the attempt started with, even though it received bytes.
        var retry = GemmaDownloadRetryState(delays: [1])
        let dropped = URLError(.networkConnectionLost)

        #expect(retry.recordFailure(dropped, lastingProgressBytes: -4_096) == .retry(after: 1))
        #expect(retry.recordFailure(dropped, lastingProgressBytes: -4_096) == .fail)
    }

    @Test func permanentFailuresAreNotRetried() {
        var retry = GemmaDownloadRetryState(delays: [1, 2])

        #expect(retry.recordFailure(
            GemmaArtifactDownloadOperation.DownloadError.httpStatus(404),
            lastingProgressBytes: 0
        ) == .fail)
        #expect(retry.recordFailure(
            GemmaArtifactDownloadOperation.DownloadError.httpStatus(403),
            lastingProgressBytes: 0
        ) == .fail)
        #expect(retry.recordFailure(URLError(.badURL), lastingProgressBytes: 0) == .fail)
    }

    @Test func transientClassificationCoversNetworkDropsAndServerErrors() {
        #expect(GemmaDownloadRetryState.isTransient(URLError(.networkConnectionLost)))
        #expect(GemmaDownloadRetryState.isTransient(URLError(.timedOut)))
        #expect(GemmaDownloadRetryState.isTransient(
            GemmaArtifactDownloadOperation.DownloadError.httpStatus(503)
        ))
        #expect(GemmaDownloadRetryState.isTransient(
            GemmaArtifactDownloadOperation.DownloadError.httpStatus(429)
        ))
        // The partial was reset to zero, so the retry starts over instead of failing.
        #expect(GemmaDownloadRetryState.isTransient(
            GemmaArtifactDownloadOperation.DownloadError.unexpectedRange
        ))
        #expect(!GemmaDownloadRetryState.isTransient(
            GemmaArtifactDownloadOperation.DownloadError.httpStatus(404)
        ))
        #expect(!GemmaDownloadRetryState.isTransient(
            GemmaArtifactDownloadOperation.DownloadError.invalidHTTPResponse
        ))
        #expect(!GemmaDownloadRetryState.isTransient(URLError(.cancelled)))
        #expect(!GemmaDownloadRetryState.isTransient(CancellationError()))
    }

    @Test func noticesAreBundledForOfflineViewing() throws {
        let url = try #require(LiteRTLMNoticesView.noticesURL(in: .main))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = try #require((attributes[.size] as? NSNumber)?.intValue)
        #expect(size > 1_000_000)
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Gemma4LocalModelManagerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
