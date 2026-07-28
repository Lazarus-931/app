import SwiftUI

/// A two-voice metaball fluid: cool droplets ripple and wave with the model's
/// speech (biased top-left), warm droplets with yours (bottom-right). They orbit,
/// merge like liquid, and glint. Rendered on the GPU via `VoiceOrb.metal`.
struct VoiceOrbView: View {
    var userLevel: Double
    var modelLevel: Double
    var size: CGFloat = 210

    private var coolColor: Color { Color(hue: 0.62, saturation: 0.82, brightness: 1.0) }
    private var warmColor: Color { Color(hue: 0.045, saturation: 0.85, brightness: 1.0) }

    var body: some View {
        let user = max(0, min(1, userLevel))
        let model = max(0, min(1, modelLevel))

        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1000)

            Rectangle()
                .fill(.black)
                .colorEffect(
                    ShaderLibrary.voiceOrb(
                        .float(Float(size)),
                        .float(Float(time)),
                        .float(Float(user)),
                        .float(Float(model))
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: coolColor.opacity(0.28 + 0.3 * model), radius: size * 0.11)
                .shadow(color: warmColor.opacity(0.22 + 0.3 * user), radius: size * 0.11)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
