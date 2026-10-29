import Foundation

/// Realtime arguments may finish even when the response is later cancelled.
/// Keep names and calls until response.done confirms that response completed.
nonisolated final class RealtimeLiveEvents: @unchecked Sendable {
    private struct FunctionItem {
        let name: String
        let callID: String
        let responseID: String
    }

    private let lock = NSLock()
    private var items: [String: FunctionItem] = [:]
    private var calls: [String: [LiveToolCall]] = [:]
    private var interrupted: Set<String> = []
    private var finished: Set<String> = []
    private var currentResponse = ""

    func parse(_ message: String) -> [LiveEvent] {
        guard let json = LiveJSON.object(message), let type = json["type"] as? String else { return [] }
        return lock.withLock {
            switch type {
            case "response.created":
                currentResponse = (json["response"] as? [String: Any])?["id"] as? String ?? ""
                if currentResponse.isEmpty { interrupted.remove(""); finished.remove("") }
                return [.responseStarted]
            case "input_audio_buffer.speech_started":
                interrupted.insert(currentResponse)
                return [.userSpeechStarted]
            case "response.output_item.added", "response.output_item.done":
                guard let item = json["item"] as? [String: Any], item["type"] as? String == "function_call" else { return [] }
                let response = json["response_id"] as? String ?? currentResponse
                remember(item, response: response)
                if type == "response.output_item.done", (item["status"] as? String ?? "completed") == "completed" {
                    collect(item, response: response)
                }
                return []
            case "response.function_call_arguments.done":
                collect(json, response: json["response_id"] as? String ?? currentResponse)
                return []
            case "response.done":
                let response = json["response"] as? [String: Any] ?? [:]
                let id = response["id"] as? String ?? currentResponse
                guard !finished.contains(id) else { return [] }
                let status = response["status"] as? String ?? "completed"
                let successful = status == "completed" && !interrupted.contains(id)
                if successful {
                    for item in response["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "function_call" {
                        if (item["status"] as? String ?? "completed") == "completed" { collect(item, response: id) }
                    }
                }
                let ready = successful ? calls[id] ?? [] : []
                calls.removeValue(forKey: id)
                items = items.filter { $0.value.responseID != id }
                if !id.isEmpty { finished.insert(id) }
                interrupted.remove(id)
                var events: [LiveEvent] = ready.isEmpty ? [] : [.toolCalls(ready)]
                if status == "failed" {
                    let details = response["status_details"] as? [String: Any]
                    let error = details?["error"] as? [String: Any]
                    events.append(.error(error?["message"] as? String ?? "The voice response failed.", code: error?["code"] as? String))
                }
                events.append(.responseDone(hasToolCalls: !ready.isEmpty, successful: successful))
                return events
            default:
                return OpenAIRealtimeWire.parseRealtimeEvent(message)
            }
        }
    }

    private func remember(_ item: [String: Any], response: String) {
        guard !finished.contains(response), let id = item["id"] as? String,
              let callID = item["call_id"] as? String, let name = item["name"] as? String, !name.isEmpty else { return }
        items[id] = FunctionItem(name: name, callID: callID, responseID: response)
    }

    private func collect(_ item: [String: Any], response: String) {
        guard !finished.contains(response) else { return }
        let metadata = ((item["item_id"] ?? item["id"]) as? String).flatMap { items[$0] }
        guard let callID = item["call_id"] as? String ?? metadata?.callID,
              let name = item["name"] as? String ?? metadata?.name, !callID.isEmpty, !name.isEmpty,
              !(calls[response] ?? []).contains(where: { $0.id == callID }) else { return }
        let arguments = (item["arguments"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "{}"
        calls[response, default: []].append(LiveToolCall(id: callID, name: name, argumentsJSON: arguments))
    }
}
