import Foundation

/// The WebSocket a live session talks through; tests substitute a fake.
nonisolated protocol LiveSocket: AnyObject, Sendable {
    func send(_ text: String) async throws
    /// The next server message. Text and binary frames are both UTF-8 JSON.
    func receive() async throws -> String
    func close()
}

nonisolated enum LiveSocketError: LocalizedError, Equatable {
    /// The server answered the upgrade request with an HTTP error.
    case refused(statusCode: Int)
    /// The server closed the socket with a close frame.
    case closed(code: Int, reason: String?)
    case unexpectedMessage

    var errorDescription: String? {
        switch self {
        case .refused(let statusCode):
            String(
                localized: "The provider refused the connection (HTTP \(statusCode)).",
                comment: "Voice assistant error; the argument is the HTTP status code, such as 401."
            )
        case .closed(let code, let reason):
            // The close code is an identifier, so it is passed as text to skip digit grouping.
            reason.flatMap { $0.isEmpty ? nil : $0 } ?? String(
                localized: "The connection closed (\(String(code))).",
                comment: "Voice assistant error when the provider closes the connection without a reason; the argument is the close code, such as 1011."
            )
        case .unexpectedMessage:
            String(localized: "The provider sent a message the app can't read.", comment: "Voice assistant error when the provider sends data the app doesn't understand.")
        }
    }

    var endReason: LiveEndReason {
        switch self {
        case .refused(let statusCode): .refused(statusCode: statusCode)
        case .closed(let code, let reason): .closedByServer(code: code, reason: reason)
        case .unexpectedMessage: .failed(errorDescription ?? "")
        }
    }
}

nonisolated final class URLSessionLiveSocket: LiveSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest, session: URLSession = .shared) {
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
    }

    func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            // The setup send can fail before receive() reports a refused upgrade.
            // Keep the HTTP/close reason whichever side observes it first.
            throw Self.classify(error, response: task.response, closeCode: task.closeCode.rawValue, closeReason: task.closeReason)
        }
    }

    func receive() async throws -> String {
        do {
            return try Self.text(from: try await task.receive())
        } catch {
            throw Self.classify(error, response: task.response, closeCode: task.closeCode.rawValue, closeReason: task.closeReason)
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    static func text(from message: URLSessionWebSocketTask.Message) throws -> String {
        switch message {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: throw LiveSocketError.unexpectedMessage
        }
    }

    /// A refused upgrade (bad key, no plan, out of minutes) and a server close
    /// (hosted 4402/4408/1008/1011, a clean upstream 1000, Gemini's reason for an
    /// invalid key or model) are reported as such; anything else is the original
    /// error. The client's own close never gets here: the session stops listening first.
    static func classify(_ error: Error, response: URLResponse?, closeCode: Int, closeReason: Data?) -> Error {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            return LiveSocketError.refused(statusCode: http.statusCode)
        }
        if closeCode != URLSessionWebSocketTask.CloseCode.invalid.rawValue {
            let reason = closeReason.flatMap { String(data: $0, encoding: .utf8) }
            return LiveSocketError.closed(code: closeCode, reason: reason)
        }
        return error
    }
}
