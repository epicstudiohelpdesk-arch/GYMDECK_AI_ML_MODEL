import AppIntents
import Foundation

// Compiled into both the app and the widget extension (see the target membership
// exception in the project): the Control Center control runs this intent, which
// opens the app. Keep this file free of app-only types.

/// "Talk to Fud AI": opens the app straight into a listening voice session. Siri,
/// the Action Button (through Shortcuts) and the Control Center control run it.
struct TalkToFudAIIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Fud AI"
    static let description = IntentDescription(
        "Opens Fud AI and starts a voice conversation with the assistant.",
        categoryName: "Voice Assistant"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceAssistantLaunchRequest.request()
        return .result()
    }
}

/// A request to open the voice assistant, waiting until the app's UI is ready.
/// It is kept in the App Group defaults too, so a request recorded by the widget
/// extension's process still reaches the app.
enum VoiceAssistantLaunchRequest {
    static let pendingKey = "voiceAssistant.launch.pending"
    static let notification = Notification.Name("FudAI.voiceAssistantRequested")
    /// A request older than this is stale (for example, the app was closed before it opened).
    static let lifetime: TimeInterval = 60

    @MainActor
    static func request(now: Date = .now) {
        for defaults in stores {
            defaults.set(now.timeIntervalSince1970, forKey: pendingKey)
        }
        NotificationCenter.default.post(name: notification, object: nil)
    }

    /// True once per request: whether the assistant should open now.
    static func consumePending(now: Date = .now) -> Bool {
        var pending = false
        for defaults in stores {
            let requestedAt = defaults.double(forKey: pendingKey)
            if requestedAt > 0, now.timeIntervalSince1970 - requestedAt < lifetime {
                pending = true
            }
            defaults.removeObject(forKey: pendingKey)
        }
        return pending
    }

    private static var stores: [UserDefaults] {
        var stores: [UserDefaults] = [.standard]
        if let groupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           !groupID.isEmpty, !groupID.contains("$("),
           let shared = UserDefaults(suiteName: groupID) {
            stores.append(shared)
        }
        return stores
    }
}
