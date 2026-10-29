import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center (and Lock Screen) control that opens Fud AI straight into a
/// voice conversation. `TalkToFudAIIntent` is shared with the app target, which
/// runs it when the app opens.
@available(iOS 18.0, *)
struct VoiceAssistantControl: ControlWidget {
    static let kind = "com.apoorvdarshan.calorietracker.voiceAssistant"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: TalkToFudAIIntent()) {
                Label("Talk to Fud AI", systemImage: "waveform.circle.fill")
            }
        }
        .displayName("Talk to Fud AI")
        .description("Opens Fud AI straight into a voice conversation.")
    }
}
