import SwiftUI

/// The floating entry point on Home and the workout diary. It animates gently
/// while its tab is on screen and stops drawing otherwise.
struct VoiceAssistantHomeButton: View {
    let controller: VoiceAssistantController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            controller.start()
        } label: {
            LiveOrbView(
                mode: .idle,
                tint: AppColors.calorie,
                isPaused: !isVisible || scenePhase != .active || reduceMotion,
                minimumFrameInterval: 1.0 / 30,
                clearBackground: true
            )
            // The shader's sphere occupies 56% of its canvas. Match the
            // adjacent 60-point add button without enlarging the touch target.
            .scaleEffect(1 / 0.56)
            .frame(width: 60, height: 60)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Talk to Fud AI"))
        .accessibilityHint(Text("Starts the voice assistant"))
        .accessibilityIdentifier("voiceAssistantButton")
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}
