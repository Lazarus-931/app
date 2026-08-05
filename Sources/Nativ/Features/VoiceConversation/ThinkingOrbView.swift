import SwiftUI
import WebKit

/// Renders the `thinking-orbs` library (a React/TypeScript 2D-canvas orb) inside
/// a transparent WKWebView. We skip React entirely and drive the library's
/// React-free power surface — `resolvePreset(state, size)` + `MODE_DRAWS[mode]` —
/// from a tiny vanilla-JS loop, so this is the real library's rendering. The
/// current state is pushed in with `evaluateJavaScript`.
///
/// Loaded from esm.sh at runtime (needs network the first time; then cached).
/// Swap for a vendored offline bundle if we keep it.
struct ThinkingOrbView: NSViewRepresentable {
    /// One of the library's states: working, searching, solving, listening,
    /// connecting, weaving, composing, breathing, shaping.
    var state: String
    var size: CGFloat = 220

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // Transparent so the dark conversation background shows through.
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(
            Self.html(size: size, initialState: state),
            baseURL: URL(string: "https://esm.sh/")
        )
        context.coordinator.webView = webView
        context.coordinator.lastState = state
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastState != state else { return }
        context.coordinator.lastState = state
        webView.evaluateJavaScript("window.setOrbState && window.setOrbState('\(state)')", completionHandler: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var webView: WKWebView?
        var lastState: String = ""
    }

    private static func html(size: CGFloat, initialState: String) -> String {
        let px = Int(size)
        return """
        <!doctype html>
        <html>
        <head><meta charset="utf-8">
        <style>
          html, body { margin: 0; height: 100%; background: transparent; overflow: hidden; }
          #wrap { display: flex; align-items: center; justify-content: center; height: 100vh; }
          canvas { width: \(px)px; height: \(px)px; }
        </style>
        </head>
        <body>
          <div id="wrap"><canvas id="orb"></canvas></div>
          <script type="module">
            import { resolvePreset, MODE_DRAWS } from 'https://esm.sh/thinking-orbs@0.2.0?bundle';
            const size = \(px);
            const canvas = document.getElementById('orb');
            const dpr = Math.min(2, window.devicePixelRatio || 1);
            canvas.width = Math.round(size * dpr);
            canvas.height = Math.round(size * dpr);
            const ctx = canvas.getContext('2d');
            let current = resolvePreset('\(initialState)', size);
            window.setOrbState = (s) => { try { current = resolvePreset(s, size); } catch (e) {} };
            function loop() {
              const { mode, speed, opts } = current;
              const draw = MODE_DRAWS[mode];
              ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
              ctx.clearRect(0, 0, size, size);
              if (draw) draw(ctx, size, (performance.now() / 1000) * speed, true, opts);
              requestAnimationFrame(loop);
            }
            requestAnimationFrame(loop);
          </script>
        </body>
        </html>
        """
    }
}
