import AppKit
import MLXServerKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let textView = NSTextView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MLX VLM Server Demo"
        window.center()

        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = "Running bundled mlx-vlm-server --help...\n"

        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        window.contentView?.addSubview(scrollView)
        window.makeKeyAndOrderFront(nil)
        self.window = window

        DispatchQueue.global(qos: .userInitiated).async {
            let output: String
            do {
                output = try MLXVLMServer.run(arguments: ["--help"])
            } catch {
                output = String(describing: error)
            }
            DispatchQueue.main.async {
                self.textView.string = output
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
