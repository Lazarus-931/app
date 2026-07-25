import SwiftUI

/// The voice-session UI. Expanded: a scrim over the chat with the orb centered —
/// tapping the orb minimizes it. Minimized: just the orb sitting directly above the
/// composer, still listening, while the composer stays usable; tapping it again ends
/// the session. There is no separate end button — the orb is the only control.
struct VoiceSessionOverlay: View {
    @ObservedObject var controller: VoiceSessionController
    var onEnd: () -> Void

    var body: some View {
        if controller.isMinimized {
            minimized
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else {
            expanded
                .transition(.opacity)
        }
    }

    private var expanded: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture {}

            VStack(spacing: 24) {
                Spacer()

                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        controller.toggleMinimized()
                    }
                } label: {
                    VoiceOrbView(
                        userLevel: controller.userLevel,
                        modelLevel: controller.modelLevel,
                        size: 210
                    )
                }
                .buttonStyle(.plain)
                .help("Minimize")
                .accessibilityLabel("Minimize voice conversation")

                Text(controller.statusText)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .animation(.easeInOut, value: controller.statusText)

                Spacer()
            }
        }
        // Keyboard escape ends the session without adding a visible button.
        .onExitCommand(perform: onEnd)
    }

    private var minimized: some View {
        VStack {
            Spacer()
            Button(action: onEnd) {
                VoiceOrbView(
                    userLevel: controller.userLevel,
                    modelLevel: controller.modelLevel,
                    size: 54
                )
            }
            .buttonStyle(.plain)
            .help("End voice conversation")
            .accessibilityLabel("End voice conversation")
            .padding(.bottom, 108)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(true)
    }
}
