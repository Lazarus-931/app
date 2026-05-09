import AppKit
import MLXServerKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow?
    private let textView = NSTextView()
    private let server = MLXServerProcessController()
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var serverActionMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureServerCallbacks()
        configureStatusItem()
        configureWindow()
        startServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if server.isRunning {
            try? server.stop(timeout: 2)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuItems()
    }

    @objc private func toggleServerFromMenu(_ sender: Any?) {
        if server.isRunning {
            stopServer()
        } else {
            startServer()
        }
    }

    @objc private func quit(_ sender: Any?) {
        NSApplication.shared.terminate(sender)
    }

    private func configureWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MLX Server Log"
        window.center()

        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        window.contentView?.addSubview(scrollView)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "MLX"
        statusItem.button?.toolTip = "MLX VLM Server"

        let menu = NSMenu()
        menu.delegate = self

        let statusMenuItem = NSMenuItem(title: "Status: MLX Server is Not Running", action: nil, keyEquivalent: "")
        let serverActionMenuItem = NSMenuItem(title: "Start Server", action: #selector(toggleServerFromMenu(_:)), keyEquivalent: "s")
        let quitMenuItem = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")

        serverActionMenuItem.target = self
        quitMenuItem.target = self

        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(serverActionMenuItem)
        menu.addItem(.separator())
        menu.addItem(quitMenuItem)

        statusItem.menu = menu
        self.statusItem = statusItem
        self.statusMenuItem = statusMenuItem
        self.serverActionMenuItem = serverActionMenuItem
        updateMenuItems()
    }

    private func configureServerCallbacks() {
        server.onOutput = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.appendLog(text)
            }
        }
        server.onTermination = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.appendLog("\nmlx-vlm-server stopped with status \(status)\n")
                self?.updateMenuItems()
            }
        }
    }

    private func startServer() {
        do {
            try server.start()
            appendLog("\nStarted mlx-vlm-server.\n")
        } catch MLXServerError.alreadyRunning {
            appendLog("\nmlx-vlm-server is already running.\n")
        } catch {
            appendLog("\nFailed to start mlx-vlm-server: \(error)\n")
        }
        updateMenuItems()
    }

    private func stopServer() {
        do {
            try server.stop()
            appendLog("\nStopping mlx-vlm-server...\n")
        } catch MLXServerError.notRunning {
            appendLog("\nmlx-vlm-server is not running.\n")
        } catch {
            appendLog("\nFailed to stop mlx-vlm-server: \(error)\n")
        }
        updateMenuItems()
    }

    private func updateMenuItems() {
        let running = server.isRunning
        statusMenuItem?.title = running
            ? "Status: MLX Server is Running"
            : "Status: MLX Server is Not Running"
        serverActionMenuItem?.title = running ? "Stop Server" : "Start Server"
    }

    private func appendLog(_ text: String) {
        textView.textStorage?.append(NSAttributedString(string: text))
        textView.scrollToEndOfDocument(nil)
    }
}
