import AppKit
import MLXServerKit
import SwiftUI

@MainActor
private final class ModelMenuIconView: NSView {
    private let imageView = NSImageView()
    private let isSelected: Bool

    init(isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 14

        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        imageView.image = NSImage(
            systemSymbolName: "cube.transparent.fill",
            accessibilityDescription: "Model"
        )?.withSymbolConfiguration(configuration)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16)
        ])
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.controlBackgroundColor.cgColor
        imageView.contentTintColor = isSelected ? .white : .secondaryLabelColor
    }
}

@MainActor
private final class ModelMenuRowView: NSView {
    private let onSelect: () -> Void
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            needsDisplay = true
        }
    }

    init(
        name: String,
        details: String,
        tooltip: String,
        capabilities: Set<LocalModelCapability>,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 44))

        let iconView = ModelMenuIconView(isSelected: isSelected)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 4
        titleRow.addArrangedSubview(nameLabel)

        for capability in LocalModelCapability.allCases where capabilities.contains(capability) {
            let capabilityImage = NSImageView()
            let symbolName: String
            let description: String
            switch capability {
            case .vision:
                symbolName = "eye.fill"
                description = "Vision"
            case .audio:
                symbolName = "waveform"
                description = "Audio"
            }
            let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            capabilityImage.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: description
            )?.withSymbolConfiguration(configuration)
            capabilityImage.contentTintColor = .secondaryLabelColor
            capabilityImage.imageScaling = .scaleProportionallyDown
            capabilityImage.toolTip = description
            capabilityImage.setContentCompressionResistancePriority(.required, for: .horizontal)
            capabilityImage.widthAnchor.constraint(equalToConstant: 13).isActive = true
            capabilityImage.heightAnchor.constraint(equalToConstant: 13).isActive = true
            titleRow.addArrangedSubview(capabilityImage)
        }

        let detailsLabel = NSTextField(labelWithString: details)
        detailsLabel.font = .systemFont(ofSize: 10)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [titleRow, detailsLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        labels.translatesAutoresizingMaskIntoConstraints = false

        let selectedImage = NSImageView()
        selectedImage.image = isSelected
            ? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Loaded")
            : nil
        selectedImage.contentTintColor = .controlAccentColor
        selectedImage.imageScaling = .scaleProportionallyDown
        selectedImage.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(labels)
        addSubview(selectedImage)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: selectedImage.leadingAnchor, constant: -6),

            selectedImage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            selectedImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectedImage.widthAnchor.constraint(equalToConstant: 14),
            selectedImage.heightAnchor.constraint(equalToConstant: 14)
        ])

        self.toolTip = tooltip
        setAccessibilityRole(.button)
        let capabilityDescription = capabilities
            .map(\.rawValue.capitalized)
            .sorted()
            .joined(separator: ", ")
        let accessibilitySuffix = capabilityDescription.isEmpty ? "" : ", \(capabilityDescription)"
        setAccessibilityLabel("\(name), \(details)\(accessibilitySuffix)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHovered else {
            return
        }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            return
        }
        enclosingMenuItem?.menu?.cancelTracking()
        onSelect()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

@MainActor
private final class ModelMenuSectionHeaderView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 24))

        let title = NSMutableAttributedString(
            string: "Installed ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        title.append(NSAttributedString(
            string: "models",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.controlAccentColor
            ]
        ))

        let label = NSTextField(labelWithAttributedString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow?
    private let model = MLXServerDemoModel()
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var serverActionMenuItem: NSMenuItem?
    private var modelMenuItem: NSMenuItem?
    private var localModels: [LocalModel] = []
    private var modelScanTask: Task<Void, Never>?
    private var modelScanInProgress = false
    private var modelScanError: String?
    private var lastScannedModelPath: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onMenuStateChanged = { [weak self] in
            self?.rebuildMenu()
        }

        configureMainMenu()
        configureStatusItem()
        configureWindow()
        refreshLocalModels()
        model.startServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        modelScanTask?.cancel()
        model.applicationWillTerminate()
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.menuIsOpen = true
        rebuildMenu()
        if model.metricsAreStale {
            model.refreshMetricsIfRunning(force: true)
        }
        refreshLocalModelsIfNeeded()
    }

    func menuDidClose(_ menu: NSMenu) {
        model.menuIsOpen = false
        rebuildMenu()
    }

    @objc private func toggleServerFromMenu(_ sender: Any?) {
        model.toggleServer()
    }

    @objc private func switchModelFromMenu(_ sender: NSMenuItem) {
        let rawModelID = sender.representedObject as? String
        model.switchLanguageModel(to: rawModelID?.isEmpty == false ? rawModelID : nil)
    }

    @objc private func refreshModelsFromMenu(_ sender: Any?) {
        refreshLocalModels()
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
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: ControlPanelView(model: model))
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func showMainWindow() {
        guard let window else {
            configureWindow()
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
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
        let modelMenuItem = makeModelMenuItem()
        menu.addItem(modelMenuItem)
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
        self.modelMenuItem = modelMenuItem
    }

    private func makeSessionStatsMenuItem(_ metrics: MLXServerMetrics) -> NSMenuItem {
        let item = NSMenuItem(title: "Session Stats", action: nil, keyEquivalent: "")
        let hostingView = NSHostingView(rootView: SessionStatsMenuView(
            metrics: metrics,
            updatedAt: model.lastMetricsFetchAt,
            tokenActivity: model.sessionTokenActivity
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

    private func makeModelMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: model.modelSwitchInProgress ? "Model: Loading…" : "Model: \(selectedModelMenuTitle)",
            action: nil,
            keyEquivalent: ""
        )
        item.submenu = makeModelSubmenu()
        return item
    }

    private func makeModelSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if model.modelSwitchInProgress {
            submenu.addItem(disabledMenuItem("Restarting server and loading model…"))
            return submenu
        }

        submenu.addItem(disabledMenuItem("Loaded: \(model.loadedModelDisplay)"))
        submenu.addItem(.separator())

        submenu.addItem(modelOptionMenuItem(title: "Load on demand", modelID: nil))

        let selectedModelID = model.settings.normalized().languageModelID
        if let selectedModelID,
           !localModels.contains(where: { $0.repoID == selectedModelID }) {
            submenu.addItem(modelOptionMenuItem(
                title: missingModelMenuLabel(selectedModelID),
                modelID: selectedModelID
            ))
        }

        if !localModels.isEmpty {
            submenu.addItem(.separator())
            submenu.addItem(installedModelsHeaderMenuItem())
        }

        for localModel in localModels {
            submenu.addItem(modelRowMenuItem(localModel))
        }

        if localModels.isEmpty, selectedModelID == nil {
            let message = modelScanInProgress
                ? "Scanning for local models…"
                : modelScanError ?? "No local models found"
            submenu.addItem(disabledMenuItem(message))
        }

        submenu.addItem(.separator())
        let refreshItem = NSMenuItem(
            title: modelScanInProgress ? "Refreshing Models…" : "Refresh Models",
            action: #selector(refreshModelsFromMenu(_:)),
            keyEquivalent: ""
        )
        refreshItem.target = self
        refreshItem.isEnabled = !modelScanInProgress
        submenu.addItem(refreshItem)

        return submenu
    }

    private func modelOptionMenuItem(
        title: String,
        modelID: String?
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(switchModelFromMenu(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = modelID ?? ""
        item.state = model.settings.normalized().languageModelID == modelID ? .on : .off
        return item
    }

    private func installedModelsHeaderMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Installed models", action: nil, keyEquivalent: "")
        item.view = ModelMenuSectionHeaderView()
        return item
    }

    private func modelRowMenuItem(_ localModel: LocalModel) -> NSMenuItem {
        let item = NSMenuItem(title: localModel.repoID, action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.view = ModelMenuRowView(
            name: modelDisplayName(localModel.repoID),
            details: modelDetails(localModel),
            tooltip: modelMenuTooltip(localModel),
            capabilities: localModel.capabilities,
            isSelected: model.settings.normalized().languageModelID == localModel.repoID,
            onSelect: { [weak self] in
                self?.model.switchLanguageModel(to: localModel.repoID)
            }
        )
        return item
    }

    private var selectedModelMenuTitle: String {
        guard let modelID = model.settings.normalized().languageModelID else {
            return "On demand"
        }
        let shortName = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return MLXServerDemoFormatting.truncateModelName(shortName, maxLength: 28)
    }

    private func modelDisplayName(_ modelID: String) -> String {
        let shortName = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return MLXServerDemoFormatting.truncateModelName(shortName, maxLength: 34)
    }

    private func missingModelMenuLabel(_ modelID: String) -> String {
        let shortName = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return "\(MLXServerDemoFormatting.truncateModelName(shortName, maxLength: 34))  ·  Not found"
    }

    private func modelDetails(_ localModel: LocalModel) -> String {
        var details: [String] = []
        if let sizeBytes = localModel.sizeBytes {
            details.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
        }
        if let contextSize = localModel.contextSize {
            details.append("\(compactContextSize(contextSize)) ctx")
        }
        return details.isEmpty ? "Model details unavailable" : details.joined(separator: " · ")
    }

    private func modelMenuTooltip(_ localModel: LocalModel) -> String {
        var lines = [localModel.repoID]
        if let sizeBytes = localModel.sizeBytes {
            lines.append("Size: \(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))")
        }
        if let contextSize = localModel.contextSize {
            let formatted = NumberFormatter.localizedString(from: NSNumber(value: contextSize), number: .decimal)
            lines.append("Context: \(formatted) tokens")
        }
        if !localModel.capabilities.isEmpty {
            let capabilities = localModel.capabilities
                .map(\.rawValue.capitalized)
                .sorted()
                .joined(separator: ", ")
            lines.append("Capabilities: \(capabilities)")
        }
        return lines.joined(separator: "\n")
    }

    private func compactContextSize(_ value: Int) -> String {
        let million = 1024 * 1024
        if value >= million, value.isMultiple(of: million) {
            return "\(value / million)M"
        }
        if value >= 1024, value.isMultiple(of: 1024) {
            return "\(value / 1024)K"
        }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private func refreshLocalModelsIfNeeded() {
        let currentPath = model.settings.normalized().expandedModelSearchPath
        guard lastScannedModelPath != currentPath else {
            return
        }
        refreshLocalModels()
    }

    private func refreshLocalModels() {
        modelScanTask?.cancel()
        let searchPath = model.settings.normalized().expandedModelSearchPath
        modelScanInProgress = true
        modelScanError = nil
        rebuildModelSubmenu()

        modelScanTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                let models = try await LocalModelDiscovery.scan(path: searchPath)
                guard !Task.isCancelled else {
                    return
                }
                self.localModels = models
                self.lastScannedModelPath = searchPath
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self.localModels = []
                self.modelScanError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.lastScannedModelPath = searchPath
            }

            self.modelScanInProgress = false
            self.rebuildModelSubmenu()
        }
    }

    private func rebuildModelSubmenu() {
        guard let modelMenuItem else {
            return
        }
        modelMenuItem.title = model.modelSwitchInProgress
            ? "Model: Loading…"
            : "Model: \(selectedModelMenuTitle)"
        modelMenuItem.submenu = makeModelSubmenu()
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
    let tokenActivity: [Int]

    private let accent = Color(red: 0.31, green: 0.72, blue: 0.77)
    private let generatedAccent = Color(red: 0.45, green: 0.55, blue: 0.92)

    private var totalTokens: Int {
        metrics.summary.totalProcessedTokens
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .padding(.vertical, 10)

            sessionOverview

            SessionActivityPlot(values: tokenActivity, accent: accent)
                .padding(.top, 12)

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

    private var sessionOverview: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Processed tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatted(totalTokens))
                        .font(.title2.weight(.semibold).monospacedDigit())
                }

                Spacer()

                metric(
                    "Average decode",
                    MLXServerDemoFormatting.rate(metrics.summary.averageDecodeTokensPerSecond),
                    alignment: .trailing
                )
            }

            HStack(spacing: 16) {
                tokenBreakdown(
                    "Prompt",
                    value: metrics.summary.promptTokensTotal,
                    color: accent
                )
                tokenBreakdown(
                    "Generated",
                    value: metrics.summary.generatedTokensTotal,
                    color: generatedAccent
                )
            }
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
            alignment: .leading,
            spacing: 12
        ) {
            metric("Completed requests", formatted(metrics.summary.requestsCompleted))
            metric("Failed requests", formatted(metrics.summary.requestsFailed))
            metric("In flight", MLXServerDemoFormatting.integer(metrics.summary.inFlight))
            metric("Uptime", MLXServerDemoFormatting.duration(metrics.summary.uptimeSeconds))
        }
    }

    private func tokenBreakdown(_ label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(label) \(formatted(value))")
                .font(.caption)
                .foregroundStyle(.secondary)
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

private struct SessionActivityPlot: View {
    let values: [Int]
    let accent: Color

    private let sampleCount = 24

    private var plottedValues: [Int] {
        Array(repeating: 0, count: max(0, sampleCount - values.count))
            + Array(values.suffix(sampleCount))
    }

    private var maximumValue: CGFloat {
        CGFloat(max(plottedValues.max() ?? 0, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Recent token activity")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("Last ~2 min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(plottedValues.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accent.opacity(value == 0 ? 0.18 : 0.9))
                        .frame(
                            maxWidth: .infinity,
                            minHeight: value == 0 ? 2 : 4,
                            maxHeight: value == 0
                                ? 2
                                : max(4, 44 * CGFloat(value) / maximumValue)
                        )
                }
            }
            .frame(height: 46, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recent token activity")
        .accessibilityValue("\(values.reduce(0, +)) tokens across \(values.count) samples")
    }
}
