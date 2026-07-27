import SwiftUI

/// A floating, fluid cloud of soft particles that reads like drifting sand rather
/// than a hard circle. Two lobes visualize the two voices at once: the model's
/// speech pulses a cool lobe toward the top-left (`modelLevel`), and your own
/// speech pulses a warm lobe toward the bottom-right (`userLevel`).
struct VoiceOrbView: View {
    var userLevel: Double
    var modelLevel: Double
    var size: CGFloat = 210

    private let particleCount = 26

    // Cool (model) points top-left; warm (you) points bottom-right. Screen y is down.
    private let modelLobeAngle = 5.0 * .pi / 4.0
    private let userLobeAngle = .pi / 4.0

    private var coolColor: Color { Color(hue: 0.62, saturation: 0.82, brightness: 1.0) }
    private var warmColor: Color { Color(hue: 0.045, saturation: 0.85, brightness: 1.0) }

    var body: some View {
        let user = max(0, min(1, userLevel))
        let model = max(0, min(1, modelLevel))

        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                // Soft idle core so the orb stays visible when both voices are quiet.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hue: 0.63, saturation: 0.5, brightness: 1.0).opacity(0.32),
                                .clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.42
                        )
                    )
                    .blur(radius: size * 0.06)

                Canvas { context, canvasSize in
                    let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                    let baseRadius = min(canvasSize.width, canvasSize.height) * 0.22

                    for index in 0..<particleCount {
                        let isModel = index.isMultiple(of: 2)
                        let level: Double = isModel ? model : user
                        let lobeAngle: Double = isModel ? modelLobeAngle : userLobeAngle
                        let phase = Double(index)

                        // Drifting position on a wobbling ring, biased toward the lobe.
                        let ringAngle: Double = (phase / Double(particleCount)) * 2.0 * .pi
                        let wobble: Double = sin(time * 1.25 + phase) * 0.16
                            + cos(time * 0.85 + phase * 1.7) * 0.10
                        let ringFraction: Double = 0.72 + 0.28 * (0.5 + 0.5 * sin(time * 0.8 + phase))
                        let ring = baseRadius * CGFloat(ringFraction)
                        let bias = baseRadius * CGFloat(0.30 + 0.55 * level)

                        let ringX = CGFloat(cos(ringAngle) * (1.0 + wobble))
                        let ringY = CGFloat(sin(ringAngle) * (1.0 + wobble))
                        let px = center.x + ringX * ring + CGFloat(cos(lobeAngle)) * bias
                        let py = center.y + ringY * ring + CGFloat(sin(lobeAngle)) * bias

                        let blobFraction: Double = 0.11 + 0.16 * level + 0.03 * (0.5 + 0.5 * sin(time + phase))
                        let blob = size * CGFloat(blobFraction)
                        let rect = CGRect(x: px - blob / 2, y: py - blob / 2, width: blob, height: blob)
                        let opacity: Double = 0.22 + 0.6 * level
                        let color = isModel ? coolColor : warmColor
                        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))
                    }
                }
                .blur(radius: size * 0.05)
            }
            .frame(width: size, height: size)
            .shadow(
                color: coolColor.opacity(0.28 + 0.3 * model),
                radius: size * 0.11
            )
            .shadow(
                color: warmColor.opacity(0.22 + 0.3 * user),
                radius: size * 0.11
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
