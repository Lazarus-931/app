import SwiftUI

/// A simple circle that vibrates with the voices: it swells with speech and
/// shivers continuously so it always feels alive. Cool when the model speaks,
/// warm when you do.
struct VoiceOrbView: View {
    var userLevel: Double
    var modelLevel: Double
    var size: CGFloat = 210

    private var coolColor: Color { Color(hue: 0.62, saturation: 0.82, brightness: 1.0) }
    private var warmColor: Color { Color(hue: 0.045, saturation: 0.85, brightness: 1.0) }

    var body: some View {
        let user = max(0, min(1, userLevel))
        let model = max(0, min(1, modelLevel))
        let level = max(user, model)
        let tint = model >= user ? coolColor : warmColor

        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let shiver = sin(time * 21.0) * 0.010 + sin(time * 13.3) * 0.006
            let scale = 1.0 + level * 0.32 + shiver * (0.5 + level)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.5)],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.5
                    )
                )
                .frame(width: size, height: size)
                .scaleEffect(scale)
                .shadow(color: tint.opacity(0.35 + 0.4 * level), radius: size * 0.12)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
