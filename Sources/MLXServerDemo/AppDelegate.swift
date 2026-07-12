import AppKit
import MLXServerKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow?
    private let model = MLXServerDemoModel()
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var serverActionMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onMenuStateChanged = { [weak self] in
            self?.rebuildMenu()
        }

        configureMainMenu()
        configureStatusItem()
        configureWindow()
        model.startServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.applicationWillTerminate()
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.menuIsOpen = true
        rebuildMenu()
        if model.metricsAreStale {
            model.refreshMetricsIfRunning(force: true)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        model.menuIsOpen = false
        rebuildMenu()
    }

    @objc private func toggleServerFromMenu(_ sender: Any?) {
        model.toggleServer()
    }

    @objc private func quit(_ sender: Any?) {
        NSApplication.shared.terminate(sender)
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        let quitMenuItem = NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitMenuItem.target = self
        quitMenuItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quitMenuItem)

        appMenuItem.submenu = appMenu
        NSApplication.shared.mainMenu = mainMenu
    }

    private func configureWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MLX Server"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.center()
        window.contentView = NSHostingView(rootView: ControlPanelView(model: model))
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "MLX"
        statusItem.button?.toolTip = "MLX VLM Server"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        self.statusItem = statusItem
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let statusItem else {
            return
        }

        let menu = statusItem.menu ?? NSMenu()
        menu.delegate = self
        menu.removeAllItems()

        let statusMenuItem: NSMenuItem
        if model.isRunning, let metrics = model.metrics {
            statusMenuItem = makeSessionStatsMenuItem(metrics)
        } else {
            statusMenuItem = NSMenuItem(
                title: model.isRunning ? model.unavailableMetricsText : "MLX Server is Not Running",
                action: nil,
                keyEquivalent: ""
            )
            statusMenuItem.isEnabled = false
        }
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())
        menu.addItem(makeServingStatsMenuItem())
        menu.addItem(.separator())

        let serverActionMenuItem = NSMenuItem(
            title: model.isRunning ? "Stop Server" : "Start Server",
            action: #selector(toggleServerFromMenu(_:)),
            keyEquivalent: "s"
        )
        serverActionMenuItem.target = self
        menu.addItem(serverActionMenuItem)

        menu.addItem(.separator())

        let quitMenuItem = NSMenuItem(
            title: "Quit", 
            action: #selector(quit(_:)), 
            keyEquivalent: "q"
        )
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        statusItem.menu = menu
        self.statusMenuItem = statusMenuItem
        self.serverActionMenuItem = serverActionMenuItem
    }

    private func makeSessionStatsMenuItem(_ metrics: MLXServerMetrics) -> NSMenuItem {
        let item = NSMenuItem(title: "Session Stats", action: nil, keyEquivalent: "")
        let hostingView = NSHostingView(rootView: SessionStatsMenuView(
            metrics: metrics,
            updatedAt: model.lastMetricsFetchAt
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 350, height: 360)
        item.view = hostingView
        return item
    }

    private func makeServingStatsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Serving Stats", action: nil, keyEquivalent: "")
        item.submenu = makeServingStatsSubmenu()
        return item
    }

    private func makeServingStatsSubmenu() -> NSMenu {
        let submenu = NSMenu()

        guard model.isRunning else {
            submenu.addItem(disabledMenuItem("Server is off"))
            return submenu
        }

        guard let metrics = model.metrics else {
            submenu.addItem(disabledMenuItem(model.unavailableMetricsText))
            return submenu
        }

        addSection("Session", entries: MLXServerDemoStats.sessionEntries(metrics), to: submenu)

        submenu.addItem(.separator())
        addSection("All-Time", entries: MLXServerDemoStats.allTimeEntries(model.allTimeStats), to: submenu)

        if let latest = metrics.latest {
            submenu.addItem(.separator())
            addSection("Latest Request", entries: MLXServerDemoStats.latestRequestEntries(latest), to: submenu)
        }

        submenu.addItem(.separator())
        addSection("Runtime", entries: MLXServerDemoStats.runtimeEntries(metrics.server), to: submenu)

        return submenu
    }

    private func addSection(_ title: String, entries: [StatsEntry], to menu: NSMenu) {
        menu.addItem(sectionHeader(title))
        for entry in entries {
            menu.addItem(makeAlignedStatsItem(label: entry.label, value: entry.value, tooltip: entry.tooltip))
        }
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.menuFont(ofSize: 0)
        ]
        item.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        return item
    }

    private func makeAlignedStatsItem(label: String, value: String, tooltip: String?) -> NSMenuItem {
        let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = tooltip
        item.view = statsRowView(label: label, value: value, tooltip: tooltip)
        return item
    }

    private func statsRowView(label: String, value: String, tooltip: String?) -> NSView {
        let row = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: StatsMenuLayout.rowWidth,
            height: StatsMenuLayout.rowHeight
        ))
        row.toolTip = tooltip

        let labelField = menuLabel(label, alignment: .left, lineBreakMode: .byTruncatingTail)
        let valueField = menuLabel(value, alignment: .right, lineBreakMode: .byTruncatingMiddle)
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueField.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueField.setContentHuggingPriority(.required, for: .horizontal)

        row.addSubview(labelField)
        row.addSubview(valueField)

        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: StatsMenuLayout.horizontalPadding),
            labelField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labelField.trailingAnchor.constraint(lessThanOrEqualTo: valueField.leadingAnchor, constant: -StatsMenuLayout.minimumColumnGap),

            valueField.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -StatsMenuLayout.horizontalPadding),
            valueField.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])

        row.setAccessibilityLabel("\(label): \(value)")
        return row
    }

    private func menuLabel(_ text: String, alignment: NSTextAlignment, lineBreakMode: NSLineBreakMode) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.alignment = alignment
        field.font = NSFont.menuFont(ofSize: 0)
        field.textColor = NSColor.secondaryLabelColor
        field.lineBreakMode = lineBreakMode
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        return field
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

private enum StatsMenuLayout {
    static let rowWidth: CGFloat = 440
    static let rowHeight: CGFloat = 22
    static let horizontalPadding: CGFloat = 14
    static let minimumColumnGap: CGFloat = 24
}

private struct SessionStatsMenuView: View {
    let metrics: MLXServerMetrics
    let updatedAt: Date?

    private let accent = Color(red: 0.31, green: 0.72, blue: 0.77)
    private let generatedAccent = Color(red: 0.45, green: 0.55, blue: 0.92)
    private let failedAccent = Color(red: 0.93, green: 0.36, blue: 0.43)

    private var totalTokens: Int {
        metrics.summary.totalProcessedTokens
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .padding(.vertical, 10)

            Text("Session")
                .font(.title3.weight(.semibold))

            sessionPlots
                .padding(.top, 10)

            Divider()
                .padding(.vertical, 10)

            metricsGrid

            if let latest = metrics.latest {
                Divider()
                    .padding(.vertical, 10)
                latestRequest(latest)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 350, height: 360, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MLX Server session statistics")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text("MLX Server")
                    .font(.headline)
                Text(updatedText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 1) {
                Text("Running")
                    .font(.headline)
                Text(MLXServerDemoFormatting.truncateModelName(
                    metrics.server.displayLoadedModel,
                    maxLength: 20
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    private var sessionPlots: some View {
        HStack(alignment: .top, spacing: 14) {
            SessionBarPlot(
                title: "Tokens · \(formatted(totalTokens))",
                bars: [
                    SessionBar(label: "Prompt", value: metrics.summary.promptTokensTotal, color: accent),
                    SessionBar(label: "Generated", value: metrics.summary.generatedTokensTotal, color: generatedAccent),
                ]
            )

            Divider()
                .frame(height: 88)

            SessionBarPlot(
                title: "Requests",
                bars: [
                    SessionBar(label: "Done", value: metrics.summary.requestsCompleted, color: accent),
                    SessionBar(label: "Failed", value: metrics.summary.requestsFailed, color: failedAccent),
                    SessionBar(label: "Active", value: metrics.summary.inFlight, color: generatedAccent),
                ]
            )
        }
        .frame(height: 92)
    }

    private var metricsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
            alignment: .leading,
            spacing: 12
        ) {
            metric("Completed requests", formatted(metrics.summary.requestsCompleted))
            metric("Average decode", MLXServerDemoFormatting.rate(metrics.summary.averageDecodeTokensPerSecond))
            metric("In flight", MLXServerDemoFormatting.integer(metrics.summary.inFlight))
            metric("Uptime", MLXServerDemoFormatting.duration(metrics.summary.uptimeSeconds))
        }
    }

    private func latestRequest(_ latest: MLXServerLatestRequest) -> some View {
        HStack(alignment: .firstTextBaseline) {
            metric(
                "Latest request",
                "\(formatted(latest.promptTokens + latest.generatedTokens)) tokens"
            )
            Spacer()
            metric(
                "Decode speed",
                MLXServerDemoFormatting.rate(latest.decodeTokensPerSecond),
                alignment: .trailing
            )
        }
    }

    private func metric(
        _ label: String,
        _ value: String,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.semibold))
        }
    }

    private var updatedText: String {
        guard let updatedAt else {
            return "Waiting for metrics"
        }

        let elapsed = max(0, Int(Date().timeIntervalSince(updatedAt)))
        if elapsed < 10 {
            return "Updated just now"
        }
        if elapsed < 60 {
            return "Updated \(elapsed)s ago"
        }
        return "Updated \(elapsed / 60)m ago"
    }

    private func formatted(_ value: Int) -> String {
        MLXServerDemoFormatting.compactCount(value).display
    }
}

private struct SessionBar: Identifiable {
    let label: String
    let value: Int
    let color: Color

    var id: String {
        label
    }
}

private struct SessionBarPlot: View {
    let title: String
    let bars: [SessionBar]

    private var maximumValue: CGFloat {
        CGFloat(max(bars.map(\.value).max() ?? 0, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(bars) { bar in
                    VStack(spacing: 3) {
                        Text(MLXServerDemoFormatting.compactCount(bar.value).display)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(bar.color.opacity(bar.value == 0 ? 0.25 : 1))
                            .frame(
                                height: bar.value == 0
                                    ? 3
                                    : max(5, 42 * CGFloat(bar.value) / maximumValue)
                            )

                        Text(bar.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(bar.label)
                    .accessibilityValue("\(bar.value)")
                }
            }
            .frame(height: 68, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
