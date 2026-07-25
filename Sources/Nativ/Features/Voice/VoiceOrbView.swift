import SwiftUI

/// A floating, ambient orb whose scale, glow, and hue drift with the live audio
/// level (0...1) — mic while you speak, playback while the model speaks. Calm and
/// beat-like rather than distracting.
struct VoiceOrbView: View {
    var level: Double
    var size: CGFloat = 200

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let clampedLevel = max(0, min(1, level))
            let pulse = 1.0 + clampedLevel * 0.34 + sin(time * 2.1) * 0.02
            let hue = 0.62 + clampedLevel * 0.06
            let drift = CGSize(
                width: sin(time * 0.7) * 0.08,
                height: cos(time * 0.9) * 0.08
            )

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hue: hue, saturation: 0.45, brightness: 1.0),
                                Color(hue: hue + 0.04, saturation: 0.7, brightness: 0.92),
                                Color(hue: hue + 0.08, saturation: 0.6, brightness: 0.7)
                                    .opacity(0.55)
                            ],
                            center: UnitPoint(x: 0.42 + drift.width, y: 0.36 + drift.height),
                            startRadius: 2,
                            endRadius: size * 0.72
                        )
                    )
                    .blur(radius: size * 0.04)
                    .scaleEffect(pulse)

                Circle()
                    .stroke(Color.white.opacity(0.12 + clampedLevel * 0.3), lineWidth: max(1, size * 0.01))
                    .scaleEffect(pulse * 1.04)
                    .blur(radius: size * 0.015)
            }
            .frame(width: size, height: size)
            .shadow(color: Color(hue: hue, saturation: 0.6, brightness: 1).opacity(0.5), radius: size * 0.12)
            .animation(.easeOut(duration: 0.12), value: level)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
