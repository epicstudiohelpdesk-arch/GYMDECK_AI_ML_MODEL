import Foundation

/// Keeps completion, timeout and cancellation attached to the scan that owns them.
/// A result may arrive before the scanner installs its continuation.
@MainActor
final class VoiceAssistantBarcodeRequest {
    private var current = UUID()
    private var continuation: CheckedContinuation<VoiceAssistantWait<String>, Never>?
    private var result: VoiceAssistantWait<String>?

    var isWaiting: Bool { continuation != nil }

    func begin() -> UUID {
        finish(.cancelled)
        current = UUID()
        result = nil
        return current
    }

    func isCurrent(_ request: UUID) -> Bool { request == current }

    func wait(for request: UUID) async -> VoiceAssistantWait<String> {
        await withCheckedContinuation { continuation in
            guard isCurrent(request) else {
                continuation.resume(returning: .cancelled)
                return
            }
            if let result {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }

    func finish(_ result: VoiceAssistantWait<String>, request: UUID? = nil) {
        if let request, !isCurrent(request) { return }
        guard self.result == nil else { return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }
}
