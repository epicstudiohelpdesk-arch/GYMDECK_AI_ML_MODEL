import Foundation
import Testing
@testable import calorietracker

@Suite("Gemma 4 artifact download", .serialized)
@MainActor
struct GemmaArtifactDownloadOperationTests {
    private let artifact = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    private let split = 70_000
    private let resolveURL = URL(string: "https://huggingface.test/resolve/pinned/model.litertlm")!

    @Test func keptBytesResumeWithARangeRequestToTheResolveURL() async throws {
        let file = try makeFile(containing: artifact.prefix(split))
        defer { removeDirectory(of: file) }
        stub([resumeReply(from: split)])

        let operation = makeOperation(file)
        try await operation.start(url: resolveURL)

        #expect(try Data(contentsOf: file) == artifact)
        #expect(operation.lastingProgressBytes == Int64(artifact.count - split))
        // The resume asks the pinned resolve URL again, never a signed CDN link an earlier
        // attempt was redirected to, which expires after an hour.
        let request = try #require(GemmaDownloadStubProtocol.requests.first)
        #expect(request.url == resolveURL)
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=\(split)-")
    }

    @Test func transferEndingEarlyKeepsItsBytesForTheNextAttempt() async throws {
        let file = try makeFile(containing: nil)
        defer { removeDirectory(of: file) }
        stub([
            GemmaDownloadStubProtocol.Reply(status: 200, body: artifact.prefix(split)),
            resumeReply(from: split)
        ])

        let first = makeOperation(file)
        let error = await failure { try await first.start(url: resolveURL) }

        // A body that stops short of the artifact is an interruption the retry loop resumes from.
        #expect(GemmaDownloadRetryState.isTransient(error))
        #expect(first.lastingProgressBytes == Int64(split))
        #expect(try Data(contentsOf: file) == artifact.prefix(split))

        try await makeOperation(file).start(url: resolveURL)

        #expect(try Data(contentsOf: file) == artifact)
        let requests = GemmaDownloadStubProtocol.requests
        #expect(requests.map(\.url) == [resolveURL, resolveURL])
        #expect(requests.first?.value(forHTTPHeaderField: "Range") == nil)
        #expect(requests.last?.value(forHTTPHeaderField: "Range") == "bytes=\(split)-")
    }

    @Test func serverIgnoringRangeReplacesTheKeptBytes() async throws {
        // Wrong kept bytes prove the 200 body replaces the partial instead of being appended.
        let file = try makeFile(containing: Data(repeating: 0x5a, count: split))
        defer { removeDirectory(of: file) }
        stub([
            GemmaDownloadStubProtocol.Reply(
                status: 200,
                headers: ["Content-Length": String(artifact.count)],
                body: artifact
            )
        ])

        try await makeOperation(file).start(url: resolveURL)

        #expect(try Data(contentsOf: file) == artifact)
    }

    @Test func restartsThatDropAtTheSamePointRunOutOfRetries() async throws {
        // Each 200 reply ignores Range and drops where the partial already ended, so every attempt
        // replaces the same bytes. None of them makes lasting progress, so the retries must end.
        let file = try makeFile(containing: artifact.prefix(split))
        defer { removeDirectory(of: file) }
        let delays: [TimeInterval] = [0, 0, 0]
        let attempts = delays.count + 1
        stub(Array(
            repeating: GemmaDownloadStubProtocol.Reply(status: 200, body: artifact.prefix(split)),
            count: attempts
        ))

        var retry = GemmaDownloadRetryState(delays: delays)
        var decisions: [GemmaDownloadRetryState.Decision] = []
        for _ in 0..<attempts {
            let operation = makeOperation(file)
            let error = await failure { try await operation.start(url: resolveURL) }
            #expect(operation.lastingProgressBytes == 0)
            decisions.append(retry.recordFailure(error, lastingProgressBytes: operation.lastingProgressBytes))
        }

        let expected: [GemmaDownloadRetryState.Decision] =
            delays.map { GemmaDownloadRetryState.Decision.retry(after: $0) } + [.fail]
        #expect(decisions == expected)
        #expect(GemmaDownloadStubProtocol.requests.count == attempts)
        #expect(try Data(contentsOf: file) == artifact.prefix(split))
    }

    @Test func unexpectedContentRangeResetsThePartialForARetry() async throws {
        let file = try makeFile(containing: artifact.prefix(split))
        defer { removeDirectory(of: file) }
        stub([
            GemmaDownloadStubProtocol.Reply(
                status: 206,
                headers: ["Content-Range": "bytes 0-\(artifact.count - 1)/\(artifact.count)"],
                body: artifact
            )
        ])

        let error = await failure { try await makeOperation(file).start(url: resolveURL) }

        #expect(GemmaDownloadRetryState.isTransient(error))
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test func httpFailureKeepsThePartial() async throws {
        let file = try makeFile(containing: artifact.prefix(split))
        defer { removeDirectory(of: file) }
        stub([GemmaDownloadStubProtocol.Reply(status: 404, body: Data("missing".utf8))])

        let error = await failure { try await makeOperation(file).start(url: resolveURL) }

        guard case .httpStatus(404)? = error as? GemmaArtifactDownloadOperation.DownloadError else {
            Issue.record("Expected HTTP 404, got \(error)")
            return
        }
        #expect(try Data(contentsOf: file) == artifact.prefix(split))
    }

    @Test func declaredSizeThatIsNotTheArtifactFailsVerification() async throws {
        let file = try makeFile(containing: nil)
        defer { removeDirectory(of: file) }
        stub([
            GemmaDownloadStubProtocol.Reply(
                status: 200,
                headers: ["Content-Length": String(artifact.count + 1)],
                body: artifact + Data([0x00])
            )
        ])

        let error = await failure { try await makeOperation(file).start(url: resolveURL) }

        guard case .invalidDownload? = error as? Gemma4LocalModelManager.LocalModelError else {
            Issue.record("Expected a verification failure, got \(error)")
            return
        }
    }

    @Test func contentRangeMustContinueExactlyWhereThePartialEnds() {
        let size: Int64 = 1_000

        #expect(GemmaArtifactDownloadOperation.continues(
            at: 400, contentRange: "bytes 400-999/1000", expectedByteCount: size
        ))
        #expect(GemmaArtifactDownloadOperation.continues(
            at: 400, contentRange: "bytes 400-999/*", expectedByteCount: size
        ))
        #expect(!GemmaArtifactDownloadOperation.continues(
            at: 400, contentRange: "bytes 0-999/1000", expectedByteCount: size
        ))
        #expect(!GemmaArtifactDownloadOperation.continues(
            at: 400, contentRange: "bytes 400-1000/1001", expectedByteCount: size
        ))
        #expect(!GemmaArtifactDownloadOperation.continues(
            at: 400, contentRange: "bytes 400-999/2000", expectedByteCount: size
        ))
        #expect(!GemmaArtifactDownloadOperation.continues(
            at: 400, contentRange: nil, expectedByteCount: size
        ))
        #expect(!GemmaArtifactDownloadOperation.continues(
            at: 400, contentRange: "bytes */1000", expectedByteCount: size
        ))
    }

    private func resumeReply(from offset: Int) -> GemmaDownloadStubProtocol.Reply {
        GemmaDownloadStubProtocol.Reply(
            status: 206,
            headers: ["Content-Range": "bytes \(offset)-\(artifact.count - 1)/\(artifact.count)"],
            body: artifact.suffix(from: offset)
        )
    }

    private func stub(_ replies: [GemmaDownloadStubProtocol.Reply]) {
        GemmaDownloadStubProtocol.replies = replies
        GemmaDownloadStubProtocol.requests = []
    }

    private func makeOperation(_ file: URL) -> GemmaArtifactDownloadOperation {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GemmaDownloadStubProtocol.self]
        return GemmaArtifactDownloadOperation(
            fileURL: file,
            expectedByteCount: Int64(artifact.count),
            fileManager: .default,
            configuration: configuration
        ) { _ in }
    }

    private func failure(_ body: () async throws -> Void) async -> Error {
        do {
            try await body()
        } catch {
            return error
        }
        Issue.record("Expected the download attempt to fail")
        return CancellationError()
    }

    /// A partial file in its own directory; `nil` leaves the file for the download to create.
    private func makeFile(containing bytes: Data?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GemmaArtifactDownloadOperationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("artifact.partial")
        if let bytes { try bytes.write(to: file) }
        return file
    }

    private func removeDirectory(of file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}

private final class GemmaDownloadStubProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data
    }

    static var replies: [Reply] = []
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard !Self.replies.isEmpty, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let reply = Self.replies.removeFirst()
        let response = HTTPURLResponse(
            url: url,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
