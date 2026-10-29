import Foundation
import os

nonisolated private let logger = Logger(subsystem: "com.apoorvdarshan.calorietracker", category: "LiveSession")

/// One live speech-to-speech connection to a provider.
///
/// Messages go out in the order they are sent. Until the provider is ready, they
/// wait in a queue; microphone audio in that queue is capped, so a slow connection
/// keeps only the most recent few seconds of speech. Events arrive on a background
/// thread through `onEvent`.
nonisolated final class LiveSession: @unchecked Sendable {
    typealias SocketFactory = @Sendable (URLRequest) -> any LiveSocket

    /// Audio waiting for a connection beyond this is dropped, oldest first.
    static let maximumQueuedAudioBytes = 24_000 * 2 * 6 // six seconds at 24 kHz

    let config: LiveSessionConfig
    let wire: any LiveWire

    private let makeSocket: SocketFactory
    private let waitForSetupTimeout: @Sendable () async throws -> Void
    private let onEvent: @Sendable (LiveEvent) -> Void

    private let lock = NSLock()
    private var socket: (any LiveSocket)?
    private var outbox: AsyncStream<String>.Continuation?
    private var connection = 0
    private var isReady = false
    private var isClosed = false
    private var queued: [(message: String, audioBytes: Int)] = []
    private var queuedAudioBytes = 0
    private var resumptionHandle: String?
    private var setupWatchdog: Task<Void, Never>?

    init(
        config: LiveSessionConfig,
        wire: any LiveWire,
        makeSocket: @escaping SocketFactory = { URLSessionLiveSocket(request: $0) },
        waitForSetupTimeout: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(20)) },
        onEvent: @escaping @Sendable (LiveEvent) -> Void
    ) {
        self.config = config
        self.wire = wire
        self.makeSocket = makeSocket
        self.waitForSetupTimeout = waitForSetupTimeout
        self.onEvent = onEvent
    }

    func connect() {
        open()
    }

    func send(audio pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        enqueue(wire.audioMessage(pcm16), audioBytes: pcm16.count)
    }

    /// A camera frame for the model to look at (no reply requested).
    func send(image jpeg: Data) {
        for message in wire.imageMessages(jpeg) {
            enqueue(message, audioBytes: 0)
        }
    }

    /// Text the app adds as the user, such as a tap on a card.
    func send(contextText text: String) {
        for message in wire.contextTextMessages(text) {
            enqueue(message, audioBytes: 0)
        }
    }

    func send(toolResponses responses: [LiveToolResponse]) {
        for message in wire.toolResponseMessages(responses) {
            enqueue(message, audioBytes: 0)
        }
    }

    /// OpenAI/xAI: asks for the next response. Nothing for Gemini.
    func requestResponse() {
        guard let message = wire.responseCreateMessage() else { return }
        enqueue(message, audioBytes: 0)
    }

    /// Tells the provider how much of reply `itemID` the user heard before speaking over it.
    func truncate(itemID: String, audioEndMs: Int) {
        guard let message = wire.truncateMessage(itemID: itemID, audioEndMs: audioEndMs) else { return }
        enqueue(message, audioBytes: 0)
    }

    func close() {
        let (socket, outbox): ((any LiveSocket)?, AsyncStream<String>.Continuation?) = lock.withLock {
            isClosed = true
            setupWatchdog?.cancel()
            setupWatchdog = nil
            connection += 1
            queued.removeAll()
            queuedAudioBytes = 0
            defer { self.socket = nil; self.outbox = nil }
            return (self.socket, self.outbox)
        }
        outbox?.finish()
        socket?.close()
    }

    // MARK: - Connection

    private func open() {
        let request = wire.request(for: config)
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let opened: (id: Int, socket: any LiveSocket, handle: String?)? = lock.withLock {
            guard !isClosed else { return nil }
            connection += 1
            isReady = false
            let socket = makeSocket(request)
            self.socket = socket
            self.outbox = continuation
            let id = connection
            setupWatchdog?.cancel()
            // Every socket needs its own acknowledgement deadline, including
            // Gemini resumptions while the controller is already live.
            setupWatchdog = Task { [weak self, waitForSetupTimeout] in
                do {
                    try await waitForSetupTimeout()
                    try Task.checkCancellation()
                } catch { return }
                self?.connectionFailed(id, URLError(.timedOut), onlyBeforeSetup: true)
            }
            return (connection, socket, resumptionHandle)
        }
        guard let opened else {
            continuation.finish()
            return
        }

        // Sender: one consumer keeps messages in order.
        Task { [weak self] in
            for await message in stream {
                do {
                    try await opened.socket.send(message)
                } catch {
                    self?.connectionFailed(opened.id, error)
                    return
                }
            }
        }

        for message in wire.setupMessages(for: config, resumptionHandle: opened.handle) {
            continuation.yield(message)
        }
        if !wire.waitsForSetupAcknowledgement {
            markReady(opened.id)
        }

        // Receiver.
        Task { [weak self] in
            while true {
                let text: String
                do {
                    text = try await opened.socket.receive()
                } catch {
                    self?.connectionFailed(opened.id, error)
                    return
                }
                guard let self else { return }
                for event in self.wire.parse(text) {
                    self.handle(event, connection: opened.id)
                }
            }
        }
    }

    private func handle(_ event: LiveEvent, connection id: Int) {
        guard lock.withLock({ id == connection && !isClosed }) else { return }
        switch event {
        case .ready:
            markReady(id)
        case .resumptionHandle(let handle):
            lock.withLock { resumptionHandle = handle }
        case .goAway:
            reconnect(from: id)
        default:
            onEvent(event)
        }
    }

    private func markReady(_ id: Int) {
        let becameReady = lock.withLock {
            guard id == connection, !isClosed, !isReady, let outbox else { return false }
            setupWatchdog?.cancel()
            setupWatchdog = nil
            // Yield under the same lock as enqueue: live microphone chunks must
            // not overtake the speech that was queued during setup.
            for item in queued { outbox.yield(item.message) }
            queued.removeAll()
            queuedAudioBytes = 0
            isReady = true
            return true
        }
        if becameReady { onEvent(.ready) }
    }

    // Locks by hand rather than with `withLock`: the closure version crashed the
    // Swift 6.3 compiler (Xcode 26), which the CodeQL Swift analysis builds with.
    private func enqueue(_ message: String, audioBytes: Int) {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        if isReady, let outbox {
            outbox.yield(message)
            lock.unlock()
            return
        }
        queued.append((message, audioBytes))
        queuedAudioBytes += audioBytes
        dropOldestQueuedAudio()
        lock.unlock()
    }

    /// Keeps only the latest few seconds of speech while waiting; other messages
    /// stay. Called with the lock held.
    private func dropOldestQueuedAudio() {
        var index = 0
        while queuedAudioBytes > Self.maximumQueuedAudioBytes, index < queued.count {
            if queued[index].audioBytes > 0 {
                queuedAudioBytes -= queued[index].audioBytes
                queued.remove(at: index)
            } else {
                index += 1
            }
        }
    }

    /// Gemini asks clients to move to a new connection before it closes one; the
    /// resumption handle carries the conversation over.
    private func reconnect(from id: Int) {
        let old: ((any LiveSocket)?, AsyncStream<String>.Continuation?)? = lock.withLock {
            guard id == connection, !isClosed else { return nil }
            // Retire the old connection first, so its closing can't end the session.
            connection += 1
            isReady = false
            setupWatchdog?.cancel()
            setupWatchdog = nil
            defer { socket = nil; outbox = nil }
            return (socket, outbox)
        }
        guard let (socket, outbox) = old else { return }
        logger.info("[Live] Moving to a new connection")
        outbox?.finish()
        socket?.close()
        open()
    }

    private func connectionFailed(_ id: Int, _ error: Error, onlyBeforeSetup: Bool = false) {
        let failed: ((any LiveSocket)?, AsyncStream<String>.Continuation?)? = lock.withLock {
            // Check readiness under the same lock as markReady so a deadline
            // racing the acknowledgement cannot close a configured session.
            guard id == connection, !isClosed, !onlyBeforeSetup || !isReady else { return nil }
            isClosed = true
            setupWatchdog?.cancel()
            setupWatchdog = nil
            isReady = false
            queued.removeAll()
            queuedAudioBytes = 0
            defer { self.socket = nil; self.outbox = nil }
            return (socket, outbox)
        }
        guard let (socket, outbox) = failed else { return }
        logger.error("[Live] Connection ended: \(error.localizedDescription, privacy: .public)")
        outbox?.finish()
        socket?.close()
        let reason = (error as? LiveSocketError)?.endReason ?? .failed(error.localizedDescription)
        onEvent(.closed(reason))
    }
}
