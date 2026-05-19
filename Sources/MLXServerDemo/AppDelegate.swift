import AppKit
import MLXServerKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow?
    private let textView = NSTextView()
    private let server = MLXServerProcessController()
    private let metricsClient = MLXServerMetricsClient()
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var serverActionMenuItem: NSMenuItem?
    private var metrics: MLXServerMetrics?
    private var metricsFetchTask: Task<Void, Never>?
    private var metricsTimer: Timer?
    private var menuIsOpen = false
    private var lastMetricsError: String?
    private var lastMetricsFetchAt: Date?
    private var allTimeStats = MLXServerAllTimeStats.load()
    private var lastPersistedSessionTotals: MLXServerSessionTotals?

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
        stopMetricsPolling(clearSession: true)
        if server.isRunning {
            try? server.stop(timeout: 2)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        rebuildMenu()
        if metricsAreStale {
            refreshMetricsIfRunning(force: true)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        rebuildMenu()
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
        statusItem.menu = menu

        self.statusItem = statusItem
        rebuildMenu()
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
                self?.stopMetricsPolling(clearSession: true)
                self?.rebuildMenu()
            }
        }
    }

    private func startServer() {
        var shouldStartMetrics = false
        do {
            try server.start()
            appendLog("\nStarted mlx-vlm-server.\n")
            shouldStartMetrics = true
        } catch MLXServerError.alreadyRunning {
            appendLog("\nmlx-vlm-server is already running.\n")
            shouldStartMetrics = true
        } catch {
            appendLog("\nFailed to start mlx-vlm-server: \(error)\n")
        }

        if shouldStartMetrics {
            startMetricsPolling()
        }
        rebuildMenu()
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
        stopMetricsPolling(clearSession: true)
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let statusItem else {
            return
        }

        let menu = statusItem.menu ?? NSMenu()
        menu.delegate = self
        menu.removeAllItems()

        let running = server.isRunning
        let statusMenuItem = NSMenuItem(
            title: running ? "Status: MLX Server is Running" : "Status: MLX Server is Not Running",
            action: nil,
            keyEquivalent: ""
        )
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        if running {
            menu.addItem(makeStatsSummaryMenuItem())
        }

        menu.addItem(.separator())
        menu.addItem(makeServingStatsMenuItem())
        menu.addItem(.separator())

        let serverActionMenuItem = NSMenuItem(
            title: running ? "Stop Server" : "Start Server",
            action: #selector(toggleServerFromMenu(_:)),
            keyEquivalent: "s"
        )
        serverActionMenuItem.target = self
        menu.addItem(serverActionMenuItem)

        menu.addItem(.separator())

        let quitMenuItem = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        statusItem.menu = menu
        self.statusMenuItem = statusMenuItem
        self.serverActionMenuItem = serverActionMenuItem
    }

    private func makeStatsSummaryMenuItem() -> NSMenuItem {
        let title: String
        if let metrics {
            let tokenCount = formatCompactCount(metrics.summary.totalProcessedTokens).display
            let requestCount = formatCompactCount(metrics.summary.requestsCompleted).display
            let rate = formatRate(metrics.summary.averageDecodeTokensPerSecond)
            title = "Stats: \(tokenCount) tokens | \(requestCount) requests | \(rate)"
        } else if lastMetricsError == nil {
            title = "Stats: Waiting for server..."
        } else {
            title = "Stats: Metrics unavailable"
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeServingStatsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Serving Stats", action: nil, keyEquivalent: "")
        item.submenu = makeServingStatsSubmenu()
        return item
    }

    private func makeServingStatsSubmenu() -> NSMenu {
        let submenu = NSMenu()

        guard server.isRunning else {
            submenu.addItem(disabledMenuItem("Server is off"))
            return submenu
        }

        guard let metrics else {
            submenu.addItem(disabledMenuItem(lastMetricsError == nil ? "Waiting for server..." : "Metrics unavailable"))
            return submenu
        }

        addSection(
            "Session",
            entries: [
                statsEntry("Requests completed", metrics.summary.requestsCompleted),
                statsEntry("Requests failed", metrics.summary.requestsFailed),
                statsEntry("In flight", metrics.summary.inFlight),
                statsEntry("Prompt tokens", metrics.summary.promptTokensTotal),
                statsEntry("Generated tokens", metrics.summary.generatedTokensTotal),
                statsEntry("Total processed tokens", metrics.summary.totalProcessedTokens),
                ("Avg decode speed", formatRate(metrics.summary.averageDecodeTokensPerSecond), nil),
                ("Avg request speed", formatRate(metrics.summary.averageRequestTokensPerSecond), nil),
                ("Uptime", formatDuration(metrics.summary.uptimeSeconds), nil),
            ],
            to: submenu
        )

        submenu.addItem(.separator())
        addSection(
            "All-Time",
            entries: [
                statsEntry("Requests completed", allTimeStats.requestsCompleted),
                statsEntry("Requests failed", allTimeStats.requestsFailed),
                statsEntry("Prompt tokens", allTimeStats.promptTokensTotal),
                statsEntry("Generated tokens", allTimeStats.generatedTokensTotal),
                statsEntry("Total processed tokens", allTimeStats.totalProcessedTokens),
                ("Avg decode speed", formatRate(allTimeStats.averageDecodeTokensPerSecond), nil),
                ("Avg request speed", formatRate(allTimeStats.averageRequestTokensPerSecond), nil),
            ],
            to: submenu
        )

        if let latest = metrics.latest {
            submenu.addItem(.separator())
            addSection(
                "Latest Request",
                entries: latestRequestEntries(latest),
                to: submenu
            )
        }

        submenu.addItem(.separator())
        addSection(
            "Runtime",
            entries: runtimeEntries(metrics.server),
            to: submenu
        )

        return submenu
    }

    private func latestRequestEntries(_ latest: MLXServerLatestRequest) -> [StatsEntry] {
        let fullModel = latest.model ?? "None"
        var entries: [StatsEntry] = [
            ("Model", truncateModelName(fullModel), fullModel),
            ("Endpoint", latest.endpoint ?? "--", nil),
            statsEntry("Prompt tokens", latest.promptTokens),
            statsEntry("Completion tokens", latest.completionTokens),
            statsEntry("Generated tokens", latest.generatedTokens),
            statsEntry("Total tokens", latest.promptTokens + latest.generatedTokens),
            ("Time to first token", formatDuration(latest.timeToFirstTokenSeconds), nil),
            ("Prefill speed", formatRate(latest.prefillTokensPerSecond), nil),
            ("Decode speed", formatRate(latest.decodeTokensPerSecond), nil),
            ("Elapsed time", formatDuration(latest.requestElapsedSeconds), nil),
        ]

        if let peakMemoryGB = latest.peakMemoryGB {
            entries.append(("Peak memory", formatGigabytes(peakMemoryGB), nil))
        }
        if latest.imageCount > 0 || latest.audioCount > 0 {
            entries.append(("Media", "\(latest.imageCount) images, \(latest.audioCount) audio", nil))
        }
        if latest.thinkingEnabled || latest.toolCalls || latest.apcEnabled {
            entries.append(("Flags", latestFlags(latest), nil))
        }

        return entries
    }

    private func runtimeEntries(_ runtime: MLXServerRuntimeSnapshot) -> [StatsEntry] {
        let loadedModel = runtime.displayLoadedModel
        var entries: [StatsEntry] = [
            ("Loaded model", truncateModelName(loadedModel), loadedModel),
            statsEntry("Queue depth", runtime.requestQueueDepth),
            ("Batching", runtime.continuousBatchingEnabled ? "On" : "Off", nil),
            ("APC", runtime.apc.enabled ? "On" : "Off", nil),
        ]

        if let contextLimit = runtime.effectiveContextLimit ?? runtime.configuredContextLimit ?? runtime.loadedContextSize {
            entries.append(statsEntry("Context limit", contextLimit))
        }
        if let toolParser = runtime.loadedToolParser {
            entries.append(("Tool parser", toolParser, nil))
        }
        if runtime.apc.enabled {
            if let tokenHitRate = runtime.apc.tokenHitRate {
                entries.append(("APC token hit rate", formatPercent(tokenHitRate), nil))
            }
            if let matchedTokens = runtime.apc.matchedTokens {
                entries.append(statsEntry("APC matched tokens", matchedTokens))
            }
            if let diskHits = runtime.apc.diskHits {
                entries.append(statsEntry("APC disk hits", diskHits))
            }
        }

        return entries
    }

    private func addSection(_ title: String, entries: [StatsEntry], to menu: NSMenu) {
        menu.addItem(sectionHeader(title))
        let tabStop = statsTabStop(for: entries)
        for entry in entries {
            menu.addItem(makeAlignedStatsItem(label: entry.label, value: entry.value, tabStop: tabStop, tooltip: entry.tooltip))
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

    private func makeAlignedStatsItem(label: String, value: String, tabStop: CGFloat, tooltip: String?) -> NSMenuItem {
        let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = tooltip

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: tabStop, options: [:])]

        let attributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: paragraph,
            .font: NSFont.menuFont(ofSize: 0)
        ]
        item.attributedTitle = NSAttributedString(string: "\(label)\t\(value)", attributes: attributes)
        return item
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func statsEntry(_ label: String, _ value: Int) -> StatsEntry {
        let formatted = formatCompactCount(value)
        return (label, formatted.display, formatted.tooltip)
    }

    private func statsTabStop(for entries: [StatsEntry]) -> CGFloat {
        guard !entries.isEmpty else {
            return 240
        }

        let font = NSFont.menuFont(ofSize: 0)
        let labelWidth = entries
            .map { measureMenuText($0.label, font: font) }
            .max() ?? 0
        let valueWidth = entries
            .map { measureMenuText($0.value, font: font) }
            .max() ?? 0
        return max(220, labelWidth + 20 + valueWidth)
    }

    private func measureMenuText(_ text: String, font: NSFont) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        return ceil(attributed.size().width)
    }

    private func latestFlags(_ latest: MLXServerLatestRequest) -> String {
        var flags: [String] = []
        if latest.thinkingEnabled {
            flags.append("thinking")
        }
        if latest.toolCalls {
            flags.append("tools")
        }
        if latest.apcEnabled {
            flags.append("APC")
        }
        return flags.isEmpty ? "--" : flags.joined(separator: ", ")
    }

    private func formatCompactCount(_ value: Int) -> (display: String, tooltip: String) {
        let raw = Self.integerFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
        let sign = value < 0 ? "-" : ""
        let absoluteValue = Double(abs(value))
        let units: [(suffix: String, factor: Double)] = [
            ("T", 1_000_000_000_000),
            ("B", 1_000_000_000),
            ("M", 1_000_000),
            ("K", 1_000),
        ]

        for unit in units where absoluteValue >= unit.factor {
            let scaled = absoluteValue / unit.factor
            let formatted = scaled >= 100
                ? String(format: "%.0f%@", scaled, unit.suffix)
                : String(format: "%.1f%@", scaled, unit.suffix)
            return (sign + formatted.replacingOccurrences(of: ".0", with: ""), raw)
        }

        return ("\(value)", raw)
    }

    private func formatRate(_ value: Double?) -> String {
        guard let value, value > 0, value.isFinite else {
            return "--"
        }
        return String(format: "%.1f tok/s", value)
    }

    private func formatDuration(_ value: Double?) -> String {
        guard let value, value >= 0, value.isFinite else {
            return "--"
        }

        if value < 1 {
            return String(format: "%.2fs", value)
        }
        if value < 60 {
            return String(format: "%.1fs", value)
        }

        let totalSeconds = Int(value.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m \(seconds)s"
    }

    private func formatGigabytes(_ value: Double) -> String {
        guard value.isFinite else {
            return "--"
        }
        return String(format: "%.2f GB", value)
    }

    private func formatPercent(_ value: Double) -> String {
        guard value.isFinite else {
            return "--"
        }
        let percent = value <= 1 ? value * 100 : value
        return String(format: "%.1f%%", percent)
    }

    private func truncateModelName(_ value: String, maxLength: Int = 48) -> String {
        guard value.count > maxLength else {
            return value
        }

        let keep = max(8, (maxLength - 3) / 2)
        let prefix = value.prefix(keep)
        let suffix = value.suffix(keep)
        return "\(prefix)...\(suffix)"
    }

    private var metricsAreStale: Bool {
        guard let lastMetricsFetchAt else {
            return true
        }
        return Date().timeIntervalSince(lastMetricsFetchAt) >= 5
    }

    private func startMetricsPolling() {
        lastMetricsError = nil
        metrics = nil
        lastPersistedSessionTotals = nil

        if metricsTimer == nil {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshMetricsIfRunning()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            metricsTimer = timer
        }

        refreshMetricsIfRunning(force: true)
    }

    private func stopMetricsPolling(clearSession: Bool) {
        metricsFetchTask?.cancel()
        metricsFetchTask = nil
        metricsTimer?.invalidate()
        metricsTimer = nil
        lastMetricsError = nil
        lastMetricsFetchAt = nil

        if clearSession {
            metrics = nil
            lastPersistedSessionTotals = nil
        }
    }

    private func refreshMetricsIfRunning(force: Bool = false) {
        guard server.isRunning else {
            stopMetricsPolling(clearSession: true)
            rebuildMenu()
            return
        }
        guard metricsFetchTask == nil else {
            return
        }
        guard force || !menuIsOpen else {
            return
        }

        let client = metricsClient
        metricsFetchTask = Task { [weak self] in
            do {
                let fetchedMetrics = try await client.fetchMetrics()
                await MainActor.run {
                    self?.handleMetricsFetchSuccess(fetchedMetrics)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.metricsFetchTask = nil
                }
            } catch {
                await MainActor.run {
                    self?.handleMetricsFetchFailure(error)
                }
            }
        }
    }

    private func handleMetricsFetchSuccess(_ fetchedMetrics: MLXServerMetrics) {
        metricsFetchTask = nil
        lastMetricsFetchAt = Date()

        guard server.isRunning else {
            metrics = nil
            return
        }

        lastMetricsError = nil
        metrics = fetchedMetrics
        persistAllTimeDelta(from: fetchedMetrics.summary)

        if !menuIsOpen {
            rebuildMenu()
        }
    }

    private func handleMetricsFetchFailure(_ error: Error) {
        metricsFetchTask = nil
        lastMetricsFetchAt = Date()
        lastMetricsError = error.localizedDescription
        metrics = nil

        if !menuIsOpen {
            rebuildMenu()
        }
    }

    private func persistAllTimeDelta(from summary: MLXServerMetricsSummary) {
        let current = MLXServerSessionTotals(summary: summary)
        let previous: MLXServerSessionTotals

        if let last = lastPersistedSessionTotals, !current.appearsReset(comparedTo: last) {
            previous = last
        } else {
            previous = .zero
        }

        let delta = current.delta(since: previous)
        lastPersistedSessionTotals = current

        guard delta.hasValues else {
            return
        }

        allTimeStats.apply(delta: delta)
        allTimeStats.save()
    }

    private func appendLog(_ text: String) {
        textView.textStorage?.append(NSAttributedString(string: text))
        textView.scrollToEndOfDocument(nil)
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

private typealias StatsEntry = (label: String, value: String, tooltip: String?)

private struct MLXServerSessionTotals {
    static let zero = MLXServerSessionTotals(
        requestsCompleted: 0,
        requestsFailed: 0,
        promptTokensTotal: 0,
        completionTokensTotal: 0,
        generatedTokensTotal: 0,
        requestTimeTotalSeconds: 0,
        decodeTimeTotalSeconds: 0
    )

    var requestsCompleted: Int
    var requestsFailed: Int
    var promptTokensTotal: Int
    var completionTokensTotal: Int
    var generatedTokensTotal: Int
    var requestTimeTotalSeconds: Double
    var decodeTimeTotalSeconds: Double

    init(
        requestsCompleted: Int,
        requestsFailed: Int,
        promptTokensTotal: Int,
        completionTokensTotal: Int,
        generatedTokensTotal: Int,
        requestTimeTotalSeconds: Double,
        decodeTimeTotalSeconds: Double
    ) {
        self.requestsCompleted = requestsCompleted
        self.requestsFailed = requestsFailed
        self.promptTokensTotal = promptTokensTotal
        self.completionTokensTotal = completionTokensTotal
        self.generatedTokensTotal = generatedTokensTotal
        self.requestTimeTotalSeconds = requestTimeTotalSeconds
        self.decodeTimeTotalSeconds = decodeTimeTotalSeconds
    }

    init(summary: MLXServerMetricsSummary) {
        requestsCompleted = summary.requestsCompleted
        requestsFailed = summary.requestsFailed
        promptTokensTotal = summary.promptTokensTotal
        completionTokensTotal = summary.completionTokensTotal
        generatedTokensTotal = summary.generatedTokensTotal
        requestTimeTotalSeconds = summary.averageRequestTimeSeconds * Double(summary.requestsCompleted)
        decodeTimeTotalSeconds = summary.averageDecodeTokensPerSecond > 0
            ? Double(summary.generatedTokensTotal) / summary.averageDecodeTokensPerSecond
            : 0
    }

    var hasValues: Bool {
        requestsCompleted > 0 ||
            requestsFailed > 0 ||
            promptTokensTotal > 0 ||
            completionTokensTotal > 0 ||
            generatedTokensTotal > 0 ||
            requestTimeTotalSeconds > 0 ||
            decodeTimeTotalSeconds > 0
    }

    func appearsReset(comparedTo previous: MLXServerSessionTotals) -> Bool {
        requestsCompleted < previous.requestsCompleted ||
            requestsFailed < previous.requestsFailed ||
            promptTokensTotal < previous.promptTokensTotal ||
            completionTokensTotal < previous.completionTokensTotal ||
            generatedTokensTotal < previous.generatedTokensTotal
    }

    func delta(since previous: MLXServerSessionTotals) -> MLXServerSessionTotals {
        MLXServerSessionTotals(
            requestsCompleted: max(0, requestsCompleted - previous.requestsCompleted),
            requestsFailed: max(0, requestsFailed - previous.requestsFailed),
            promptTokensTotal: max(0, promptTokensTotal - previous.promptTokensTotal),
            completionTokensTotal: max(0, completionTokensTotal - previous.completionTokensTotal),
            generatedTokensTotal: max(0, generatedTokensTotal - previous.generatedTokensTotal),
            requestTimeTotalSeconds: max(0, requestTimeTotalSeconds - previous.requestTimeTotalSeconds),
            decodeTimeTotalSeconds: max(0, decodeTimeTotalSeconds - previous.decodeTimeTotalSeconds)
        )
    }
}

private struct MLXServerAllTimeStats: Codable {
    var requestsCompleted: Int = 0
    var requestsFailed: Int = 0
    var promptTokensTotal: Int = 0
    var completionTokensTotal: Int = 0
    var generatedTokensTotal: Int = 0
    var requestTimeTotalSeconds: Double = 0
    var decodeTimeTotalSeconds: Double = 0
    var lastUpdated: Date?

    var totalProcessedTokens: Int {
        promptTokensTotal + generatedTokensTotal
    }

    var averageDecodeTokensPerSecond: Double? {
        guard generatedTokensTotal > 0, decodeTimeTotalSeconds > 0 else {
            return nil
        }
        return Double(generatedTokensTotal) / decodeTimeTotalSeconds
    }

    var averageRequestTokensPerSecond: Double? {
        guard completionTokensTotal > 0, requestTimeTotalSeconds > 0 else {
            return nil
        }
        return Double(completionTokensTotal) / requestTimeTotalSeconds
    }

    mutating func apply(delta: MLXServerSessionTotals) {
        requestsCompleted += delta.requestsCompleted
        requestsFailed += delta.requestsFailed
        promptTokensTotal += delta.promptTokensTotal
        completionTokensTotal += delta.completionTokensTotal
        generatedTokensTotal += delta.generatedTokensTotal
        requestTimeTotalSeconds += delta.requestTimeTotalSeconds
        decodeTimeTotalSeconds += delta.decodeTimeTotalSeconds
        lastUpdated = Date()
    }

    static func load() -> MLXServerAllTimeStats {
        let url = storageURL()
        guard let data = try? Data(contentsOf: url) else {
            return MLXServerAllTimeStats()
        }
        return (try? PropertyListDecoder().decode(MLXServerAllTimeStats.self, from: data)) ?? MLXServerAllTimeStats()
    }

    func save() {
        let url = Self.storageURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListEncoder().encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            // Stats are best-effort cache data; keep the in-memory counters.
        }
    }

    private static func storageURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.local.MLXServerDemo"
        return caches
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("MLXServerStats.plist")
    }
}
