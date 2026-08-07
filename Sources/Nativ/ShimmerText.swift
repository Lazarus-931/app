import SwiftUI

/// Text that shimmers while `active`: a `base → highlight → base` linear gradient
/// is clipped to the glyph shapes and its position swept left→right on a
/// repeating loop, so a highlight band travels across the text. When inactive it
/// renders as ordinary primary text. Inherits the caller's font / line-limit /
/// truncation so the moving mask stays aligned with the drawn text.
struct ShimmerText: View {
    let text: String
    var active: Bool
    var base: Color = .secondary
    var highlight: Color = .primary
    var duration: Double = 1.6

    @State private var phase: CGFloat = 0

    var body: some View {
        Text(text)
            .foregroundStyle(active ? base : Color.primary)
            .overlay {
                if active {
                    GeometryReader { proxy in
                        let width = max(proxy.size.width, 1)
                        LinearGradient(
                            colors: [base, highlight, base],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width)
                        .offset(x: (phase * 2 - 1) * width)
                    }
                    .mask(Text(text))
                }
            }
            .onAppear { if active { startAnimating() } }
            .onChange(of: active) { _, isActive in
                if isActive { startAnimating() }
            }
    }

    private func startAnimating() {
        phase = 0
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}
