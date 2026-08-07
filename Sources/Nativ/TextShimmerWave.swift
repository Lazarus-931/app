import SwiftUI

/// A per-character shimmer *wave*: a bright band travels across the glyphs, each
/// character easing from a dim base to a bright highlight (with a subtle lift)
/// in sequence — a flowing wave rather than a flat gradient sweep. Animates only
/// while `active`; otherwise it's plain primary text.
struct TextShimmerWave: View {
    let text: String
    var active: Bool
    var base: Color = .secondary
    var highlight: Color = .primary
    /// Seconds for the wave to travel the whole string once.
    var duration: Double = 1.1
    /// Width of the bright band, in characters.
    var spread: Double = 2.2
    /// Vertical lift (points) of the brightest characters.
    var lift: CGFloat = 1.5

    // Cap length so the per-character row can't blow out the sidebar layout.
    private var displayText: String {
        text.count > 40 ? String(text.prefix(39)) + "…" : text
    }

    var body: some View {
        if active {
            TimelineView(.animation) { timeline in
                wave(at: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            Text(text).foregroundStyle(Color.primary)
        }
    }

    private func wave(at time: TimeInterval) -> some View {
        let chars = Array(displayText)
        let travel = Double(chars.count) + spread * 2
        let progress = time.truncatingRemainder(dividingBy: duration) / duration
        let head = progress * travel - spread  // sweeps -spread … count+spread, looping
        return HStack(spacing: 0) {
            ForEach(Array(chars.enumerated()), id: \.offset) { index, character in
                let distance = abs(head - Double(index))
                let raw = max(0, 1 - distance / spread)        // triangular 0…1
                let eased = raw * raw * (3 - 2 * raw)          // smoothstep
                Text(String(character))
                    .foregroundStyle(base.mix(with: highlight, by: eased))
                    .offset(y: -CGFloat(eased) * lift)
            }
        }
    }
}
