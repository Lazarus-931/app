import SwiftUI

/// The voice-session UI. Expanded: a scrim over the chat with the orb centered and
/// an end button; the transcript stays faintly visible behind. Minimized: a small
/// orb pill just above the composer so you can keep typing or talking.
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
                    VoiceOrbView(level: controller.level, size: 210)
                }
                .buttonStyle(.plain)
                .help("Minimize")

                Text(controller.statusText)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .animation(.easeInOut, value: controller.statusText)

                Spacer()

                Button(action: onEnd) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Color.secondary.opacity(0.45), in: Circle())
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("End voice conversation")
                .accessibilityLabel("End voice conversation")
                .padding(.bottom, 36)
            }
        }
    }

    private var minimized: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        controller.toggleMinimized()
                    }
                } label: {
                    VoiceOrbView(level: controller.level, size: 44)
                }
                .buttonStyle(.plain)
                .help("Expand voice conversation")
                .accessibilityLabel("Expand voice conversation")

                Button(action: onEnd) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(.quaternary, in: Circle())
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help("End voice conversation")
                .accessibilityLabel("End voice conversation")
            }
            .padding(8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .padding(.bottom, 96)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(true)
    }
}
