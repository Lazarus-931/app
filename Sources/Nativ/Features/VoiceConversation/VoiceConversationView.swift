import SwiftUI

/// Full-screen voice-conversation mode: the orb takes over the chat surface and
/// reacts to the live conversation, with a caption and mute / end controls.
struct VoiceConversationView: View {
    @ObservedObject var controller: VoiceConversationController
    let onEnd: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.97).ignoresSafeArea()

            VStack(spacing: 26) {
                Spacer()

                ThinkingOrbView(state: thinkingOrbState, size: 240)
                    .frame(width: 260, height: 260)

                Text(stateLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(1.5)

                Text(controller.caption)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .frame(maxWidth: 460, minHeight: 60, alignment: .top)
                    .animation(.easeInOut(duration: 0.2), value: controller.caption)

                Spacer()
                controls
            }
            .padding(40)
        }
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            circleButton(
                systemName: controller.isMuted ? "mic.slash.fill" : "mic.fill",
                tint: controller.isMuted ? .orange : .white,
                help: controller.isMuted ? "Unmute" : "Mute"
            ) {
                controller.toggleMute()
            }

            circleButton(systemName: "xmark", tint: .white, background: .red, help: "End conversation") {
                controller.stop()
                onEnd()
            }
        }
        .padding(.bottom, 8)
    }

    private func circleButton(
        systemName: String,
        tint: Color,
        background: Color = Color.white.opacity(0.12),
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 56, height: 56)
                .background(Circle().fill(background))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var stateLabel: String {
        switch controller.state {
        case .connecting: return "Connecting"
        case .initializing: return "Starting"
        case .listening: return controller.isMuted ? "Muted" : "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .disconnected: return "Ended"
        case .unknown: return ""
        }
    }

    /// Maps the conversation state onto a thinking-orbs animation verb.
    private var thinkingOrbState: String {
        switch controller.state {
        case .connecting, .initializing: return "connecting"
        case .listening: return "listening"
        case .thinking: return "working"
        case .speaking: return "composing"
        case .disconnected, .unknown: return "breathing"
        }
    }

    /// Two-color orb tint per state, for at-a-glance feedback.
    private var colors: (Color, Color) {
        switch controller.state {
        case .thinking:
            return (Color(red: 0.62, green: 0.55, blue: 0.98), Color(red: 0.40, green: 0.36, blue: 0.85))
        case .speaking:
            return (Color(red: 0.45, green: 0.85, blue: 0.80), Color(red: 0.30, green: 0.68, blue: 0.72))
        default: // listening / connecting
            return (Color(red: 0.60, green: 0.78, blue: 1.0), Color(red: 0.42, green: 0.58, blue: 0.95))
        }
    }
}
