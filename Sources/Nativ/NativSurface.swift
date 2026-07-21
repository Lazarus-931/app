import AppKit
import SwiftUI

extension Color {
    static let nativWindow = nativSurface(lightWhite: 0.94, fallback: .windowBackgroundColor)
    static let nativPanel = nativSurface(lightWhite: 0.975, fallback: .controlBackgroundColor)
    static let nativMark = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor.black : NSColor(white: 0.86, alpha: 1)
    })

    private static func nativSurface(lightWhite: CGFloat, fallback: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? fallback : NSColor(white: lightWhite, alpha: 1)
        })
    }
}
