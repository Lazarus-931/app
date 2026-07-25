import SwiftUI

/// A floating orb that visibly pulses with the two voices in a conversation. Your
/// microphone swells a warm lobe toward the bottom-right, the model's speech swells a
/// cool lobe toward the top-left, and the whole orb breathes with whichever voice is
/// loudest — so it plainly "vibrates" as either of you speaks, and rests calmly when
/// both are quiet.
struct VoiceOrbView: View {
    var userLevel: Double
    var modelLevel: Double
    var size: CGFloat = 210

    private var coolColor: Color { Color(hue: 0.60, saturation: 0.85, brightness: 1.0) }
    private var warmColor: Color { Color(hue: 0.045, saturation: 0.85, brightness: 1.0) }

    var body: some View {
        let user = max(0.0, min(1.0, userLevel))
        let model = max(0.0, min(1.0, modelLevel))
        let active = max(user, model)
        let leadingWarm = user >= model
        let coreColor = leadingWarm ? warmColor : coolColor

        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let breathe = 0.5 + 0.5 * sin(time * 1.6)

            ZStack {
                reactiveRings(active: active, warm: leadingWarm, time: time)
                lobe(color: coolColor, level: model, angle: 5.0 * .pi / 4.0, time: time, seed: 0.0)
                lobe(color: warmColor, level: user, angle: .pi / 4.0, time: time, seed: 2.0)
                core(color: coreColor, active: active, breathe: breathe)
            }
            .frame(width: size, height: size)
            // The unmistakable "vibrating with voice": the whole orb pulses with amplitude.
            .scaleEffect(pulseScale(active: active, breathe: breathe))
            .shadow(color: coolColor.opacity(0.25 + 0.45 * model), radius: size * 0.12)
            .shadow(color: warmColor.opacity(0.20 + 0.45 * user), radius: size * 0.12)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func pulseScale(active: Double, breathe: Double) -> CGFloat {
        CGFloat(1.0 + 0.22 * active + 0.02 * breathe)
    }

    /// Concentric rings that ripple outward only while a voice is active.
    private func reactiveRings(active: Double, warm: Bool, time: Double) -> some View {
        let color = warm ? warmColor : coolColor
        return ForEach(0..<3) { index in
            let phase = Double(index) / 3.0
            let pulse = 0.5 + 0.5 * sin(time * 2.2 - phase * 3.0)
            let ringLevel = active * pulse
            let diameter = size * CGFloat(0.55 + 0.55 * ringLevel)
            Circle()
                .stroke(color.opacity(0.35 * ringLevel), lineWidth: 2)
                .frame(width: diameter, height: diameter)
                .blur(radius: 1.5)
        }
    }

    /// One colored voice lobe that reaches outward and swells with its level.
    private func lobe(color: Color, level: Double, angle: Double, time: Double, seed: Double) -> some View {
        let drift = 0.06 * (0.5 + 0.5 * sin(time * 1.1 + seed))
        let reach = size * CGFloat(0.10 + 0.24 * level + drift)
        let diameter = size * CGFloat(0.34 + 0.36 * level)
        let dx = CGFloat(cos(angle)) * reach
        let dy = CGFloat(sin(angle)) * reach
        return Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.55 + 0.40 * level), color.opacity(0.0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .offset(x: dx, y: dy)
            .blur(radius: size * 0.04)
    }

    /// The bright breathing center that blends both voices and swells with amplitude.
    private func core(color: Color, active: Double, breathe: Double) -> some View {
        let coreRadius = size * CGFloat(0.20 + 0.16 * active + 0.02 * breathe)
        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.6 + 0.3 * active),
                        color.opacity(0.85),
                        color.opacity(0.0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: coreRadius
                )
            )
            .frame(width: coreRadius * 2, height: coreRadius * 2)
            .blur(radius: size * 0.03)
    }
}
