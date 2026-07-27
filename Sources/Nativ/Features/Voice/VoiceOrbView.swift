import SwiftUI

/// A voice orb: a soft circle whose membrane vibrates with whoever is speaking. Your
/// microphone tints it warm, the model's speech tints it cool. When both are quiet it
/// rests as a calm circle; as either of you speaks it ripples outward with amplitude.
///
/// The ripple is time-driven (60fps) and the level only modulates its intensity, so the
/// vibration stays fluid even though the audio level arrives in coarser 30fps steps.
struct VoiceOrbView: View {
    var userLevel: Double
    var modelLevel: Double
    var size: CGFloat = 210

    private var coolColor: Color { Color(hue: 0.60, saturation: 0.85, brightness: 1.0) }
    private var warmColor: Color { Color(hue: 0.045, saturation: 0.85, brightness: 1.0) }

    var body: some View {
        let user = max(0.0, min(1.0, userLevel))
        let model = max(0.0, min(1.0, modelLevel))
        let level = max(user, model)
        let tint = user >= model ? warmColor : coolColor

        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let baseRadius = min(canvasSize.width, canvasSize.height) * 0.33
                let membrane = Self.membranePath(
                    center: center, baseRadius: baseRadius, level: level, time: time
                )

                // Soft glow fill inside the vibrating membrane.
                context.fill(
                    membrane,
                    with: .radialGradient(
                        Gradient(colors: [
                            tint.opacity(0.30 + 0.45 * level),
                            tint.opacity(0.05)
                        ]),
                        center: center,
                        startRadius: 0,
                        endRadius: baseRadius * 1.3
                    )
                )
                // Crisp vibrating outline.
                context.stroke(
                    membrane,
                    with: .color(tint.opacity(0.85)),
                    lineWidth: 2.0 + CGFloat(1.6 * level)
                )

                // Inner core that brightens and grows with amplitude.
                let coreRadius = baseRadius * CGFloat(0.16 + 0.32 * level)
                let coreRect = CGRect(
                    x: center.x - coreRadius,
                    y: center.y - coreRadius,
                    width: coreRadius * 2,
                    height: coreRadius * 2
                )
                context.fill(
                    Path(ellipseIn: coreRect),
                    with: .radialGradient(
                        Gradient(colors: [
                            Color.white.opacity(0.55 + 0.4 * level),
                            tint.opacity(0.55),
                            tint.opacity(0.0)
                        ]),
                        center: center,
                        startRadius: 0,
                        endRadius: coreRadius
                    )
                )
            }
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(0.25 + 0.4 * level), radius: size * 0.1)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// A closed radial waveform. Its radius ripples with `level` via a few harmonics; a
    /// tiny idle wobble keeps it alive when quiet.
    private static func membranePath(
        center: CGPoint, baseRadius: CGFloat, level: Double, time: Double
    ) -> Path {
        var path = Path()
        let steps = 140
        let amplitude = 0.02 + 0.24 * level
        for index in 0...steps {
            let theta = Double(index) / Double(steps) * 2.0 * .pi
            let wobble =
                sin(theta * 3.0 + time * 3.0) * 0.5
                + sin(theta * 5.0 - time * 2.3) * 0.3
                + sin(theta * 8.0 + time * 4.1) * 0.2
            let idle = sin(theta * 2.0 + time * 0.9) * 0.02
            let radius = baseRadius * CGFloat(1.0 + idle + amplitude * wobble)
            let point = CGPoint(
                x: center.x + CGFloat(cos(theta)) * radius,
                y: center.y + CGFloat(sin(theta)) * radius
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}
