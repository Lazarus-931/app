import SwiftUI

/// The voice-session UI. Expanded: a scrim over the chat with the orb centered —
/// tapping the orb minimizes it. Minimized: just the orb sitting directly above the
/// composer, still listening, while the composer stays usable; tapping it again ends
/// the session. There is no separate end button — the orb is the only control.
struct VoiceSessionOverlay: View {
    @ObservedObject var controller: VoiceSessionController
    var onEnd: () -> Void
    @State private var isHoveringMinimized = false

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
            HStack(spacing: 4) {
                // Tap the small blob to expand back to the full-screen orb.
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        controller.toggleMinimized()
                    }
                } label: {
                    VoiceOrbView(
                        userLevel: controller.userLevel,
                        modelLevel: controller.modelLevel,
                        size: 54
                    )
                }
                .buttonStyle(.plain)
                .help("Expand voice conversation")
                .accessibilityLabel("Expand voice conversation")

                // On hover, an end button slides out from the orb's right edge.
                Button(action: onEnd) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.14), radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .help("End voice conversation")
                .accessibilityLabel("End voice conversation")
                .opacity(isHoveringMinimized ? 1 : 0)
                .offset(x: isHoveringMinimized ? 0 : -18)
                .allowsHitTesting(isHoveringMinimized)
            }
            .padding(6)
            .contentShape(.rect)
            .onHover { isHoveringMinimized = $0 }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isHoveringMinimized)
            .padding(.bottom, 108)
        }
        .frame(maxWidth: .infinity)
    }
}
