import Combine
import Foundation
import NativServerKit

struct SessionTokenActivitySample: Equatable, Sendable {
    let recordedAt: Date
    let promptTokens: Int
    let generatedTokens: Int

    var totalTokens: Int {
        promptTokens + generatedTokens
    }
}

@MainActor
final class NativModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var logText = ""
    @Published private(set) var metrics: NativMetrics?
    @Published private(set) var lastMetricsError: String?
    @Published private(set) var lastMetricsFetchAt: Date?
    @Published private(set) var allTimeStats = NativAllTimeStats()
    @Published private(set) var sessionTokenActivity: [SessionTokenActivitySample] = []
    @Published private(set) var modelSwitchInProgress = false
    @Published private(set) var cpuIsRunning = false
    @Published private(set) var cpuMetrics: NativMetrics?
    @Published private(set) var metricsLoading = false
    @Published private(set) var modelPreloadFailureNotice: String?
    let environmentHuggingFaceToken = HuggingFaceCachePath.resolvedToken
    @Published var settings = NativSettings.load() {
        didSet {
            settings.save()
        }
    }

    var menuIsOpen = false
    var onMenuStateChanged: (() -> Void)?

    private let server = NativProcessController()
    private let cpuServer = NativProcessController()
    private var metricsClient = NativMetricsClient()
    private var cpuMetricsClient = NativMetricsClient()
    private var cpuMetricsFetchTask: Task<Void, Never>?
    private var metricsFetchTask: Task<Void, Never>?
    private var metricsTimer: Timer?
    private var metricsStartupGraceUntil: Date?
    private var settingsAppliedAtServerStart: NativSettings?
    private var previousSessionPromptTokenCount: Int?
    private var previousSessionGeneratedTokenCount: Int?
    private var preservedSessionMetrics: NativMetrics?
    private var preservedSessionTokenActivity: [SessionTokenActivitySample] = []
    private var isStoppingForModelSwitch = false
    private var isRecoveringWithoutPreload = false
    private var didAttemptPreloadRecovery = false
    private var sawModelLoadFailureInOutput = false

    private let maxLogCharacters = 250_000
    private var logAtLineStart = true
    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    private let maxSessionActivitySamples = 120

    init() {
        NativAllTimeStats.removeLegacyStorage()
        allTimeStats = NativAllTimeStats.load(from: currentAnalyticsDatabaseURL())
        configureServerCallbacks()
        isRunning = server.isRunning
    }

    var metricsAreStale: Bool {
        guard let lastMetricsFetchAt else {
            return true
        }
        return Date().timeIntervalSince(lastMetricsFetchAt) >= 5
    }

    var loadedModelDisplay: String {
        metrics?.server.displayLoadedModel ?? "None"
    }

    var sessionStatsDisplayMetrics: NativMetrics? {
        metrics ?? preservedSessionMetrics
    }

    var sessionStatsDisplayTokenActivity: [SessionTokenActivitySample] {
        metrics == nil ? preservedSessionTokenActivity : sessionTokenActivity
    }

    var sessionStatsArePreserved: Bool {
        metrics == nil && preservedSessionMetrics != nil
    }

    var selectedModelDisplay: String {
        settings.normalized().languageModelID ?? "On demand"
    }

    var analyticsDatabaseURL: URL {
        currentAnalyticsDatabaseURL(runtimePath: metrics?.server.analyticsDatabasePath)
    }

    var effectiveHuggingFaceToken: String? {
        HuggingFaceAuthentication.effectiveToken(
            customToken: settings.huggingFaceToken,
            environmentToken: environmentHuggingFaceToken
        )
    }

    var unavailableMetricsText: String {
        lastMetricsError == nil ? "Waiting for server..." : "Metrics unavailable"
    }

    var settingsRequireRestart: Bool {
        guard isRunning, let settingsAppliedAtServerStart else {
            return false
        }
        return !settings.hasSameLaunchConfiguration(as: settingsAppliedAtServerStart)
    }

    var cpuLoadedModelID: String? {
        cpuMetrics?.server.loadedModel
    }

    var cpuChatModelID: String? {
        cpuLoadedModelID ?? settings.normalized().cpuLanguageModelID
    }

    var cpuMenuModelDisplay: String {
        cpuMetrics?.server.displayLoadedModel
            ?? settings.normalized().cpuLanguageModelID
            ?? "Loading model\u{2026}"
    }

    var cpuAnalyticsDatabaseURL: URL? {
        guard isRunning else {
            return nil
        }
        return NativAnalyticsStore.cpuDatabaseURL()
    }

    func startServer(recoveringWithoutPreload: Bool = false) {
        var shouldStartMetrics = false
        let applied = settings.normalized()
        if !recoveringWithoutPreload {
            didAttemptPreloadRecovery = false
            sawModelLoadFailureInOutput = false
            modelPreloadFailureNotice = nil
        }
        isRecoveringWithoutPreload = recoveringWithoutPreload
        let launchArguments = recoveringWithoutPreload
            ? launchArgumentsWithoutPreload()
            : settings.launchArguments
        metricsClient = NativMetricsClient(
            baseURL: URL(string: "http://127.0.0.1:\(applied.serverPort)")!
        )
        cpuMetricsClient = NativMetricsClient(
            baseURL: URL(string: "http://127.0.0.1:\(applied.cpuServerPort)")!
        )
        IntegrationProfileManager.serverPort = applied.serverPort
        var launchEnvironment = settings.launchEnvironment
        launchEnvironment["MLX_PLATFORM_ANALYTICS_DB_PATH"] = currentAnalyticsDatabaseURL().path
        launchEnvironment["MLX_PLATFORM_CPU_ANALYTICS_DB_PATH"] = NativAnalyticsStore.cpuDatabaseURL().path
        do {
            try server.start(
                arguments: launchArguments,
                environment: launchEnvironment
            )
            isRunning = true
            settingsAppliedAtServerStart = settings.normalized()
            appendLog("\nStarted mlx-vlm-server.\n")
            shouldStartMetrics = true
        } catch NativError.alreadyRunning {
            isRunning = true
            settingsAppliedAtServerStart = settings.normalized()
            appendLog("\nmlx-vlm-server is already running.\n")
            shouldStartMetrics = true
        } catch {
            appendLog("\nFailed to start mlx-vlm-server: \(error)\n")
        }

        if isRunning {
            startCPUServerIfNeeded(applied, environment: launchEnvironment)
        }

        if shouldStartMetrics {
            startMetricsPolling()
        }
        notifyMenuStateChanged()
    }

    private func startCPUServerIfNeeded(_ applied: NativSettings, environment: [String: String]) {
        guard applied.requiresCPUServer else {
            cpuIsRunning = false
            return
        }
        do {
            try cpuServer.start(
                arguments: applied.cpuLaunchArguments,
                environment: environment
            )
            cpuIsRunning = true
            appendLog("\nStarted CPU mlx-vlm-server.\n")
        } catch NativError.alreadyRunning {
            cpuIsRunning = true
        } catch {
            cpuIsRunning = false
            appendLog("\nFailed to start CPU mlx-vlm-server: \(error)\n")
        }
    }

    /// Launch arguments with model pre-loads removed, so the server can start
    /// on-demand after a configured model fails to pre-load.
    private func launchArgumentsWithoutPreload() -> [String] {
        var recoverySettings = settings
        recoverySettings.languageModelID = nil
        recoverySettings.cpuLanguageModelID = nil
        recoverySettings.speculativeDecodingEnabled = false
        return recoverySettings.launchArguments
    }

    /// True when the server exited during startup because the configured model
    /// failed to load — in which case we restart once without pre-loading it.
    private func shouldRecoverFromPreloadFailure(status: Int32) -> Bool {
        status != 0
            && !didAttemptPreloadRecovery
            && !isRecoveringWithoutPreload
            && !isStoppingForModelSwitch
            && sawModelLoadFailureInOutput
            && settingsAppliedAtServerStart?.languageModelID != nil
    }

    func stopServer(preserveSessionStats: Bool = false) {
        if preserveSessionStats {
            preserveCurrentSessionStats()
        } else {
            modelSwitchInProgress = false
            clearPreservedSessionStats()
        }

        do {
            appendLog("\nStopping mlx-vlm-server...\n")
            try server.stop()
        } catch NativError.notRunning {
            appendLog("\nmlx-vlm-server is not running.\n")
        } catch {
            appendLog("\nFailed to stop mlx-vlm-server: \(error)\n")
        }

        try? cpuServer.stop()

        isRunning = server.isRunning
        cpuIsRunning = cpuServer.isRunning
        if !isRunning {
            cpuMetrics = nil
            settingsAppliedAtServerStart = nil
        }
        stopMetricsPolling(clearSession: true)
        notifyMenuStateChanged()
    }

    func restartServer() {
        stopServer()
        startServer()
    }

    func toggleServer() {
        if isRunning {
            stopServer()
        } else {
            startServer()
        }
    }

    func dismissModelPreloadFailureNotice() {
        modelPreloadFailureNotice = nil
    }

    func switchLanguageModel(to modelID: String?) {
        guard !modelSwitchInProgress else {
            return
        }

        var nextSettings = settings
        nextSettings.languageModelID = modelID
        let normalizedModelID = nextSettings.normalized().languageModelID
        let selectionIsAlreadyApplied = settings.normalized().languageModelID == normalizedModelID
            && server.isRunning
            && !settingsRequireRestart
        guard !selectionIsAlreadyApplied else {
            return
        }

        settings.languageModelID = normalizedModelID
        modelSwitchInProgress = true
        notifyMenuStateChanged()

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            if self.server.isRunning {
                self.isStoppingForModelSwitch = true
                self.stopServer(preserveSessionStats: true)
                await Task.yield()
                self.isStoppingForModelSwitch = false
            }

            guard !self.server.isRunning else {
                self.appendLog("\nCould not stop the current server to switch models.\n")
                self.modelSwitchInProgress = false
                self.clearPreservedSessionStats()
                self.notifyMenuStateChanged()
                return
            }
            self.startServer()
            if !self.server.isRunning {
                self.modelSwitchInProgress = false
                self.clearPreservedSessionStats()
                self.notifyMenuStateChanged()
            }
        }
    }

    func switchCPUModel(to modelID: String?) {
        settings.cpuLanguageModelID = modelID
        guard isRunning else {
            return
        }
        cpuMetrics = nil
        notifyMenuStateChanged()
    }

    func applicationWillTerminate() {
        stopMetricsPolling(clearSession: true)
        if server.isRunning {
            try? server.stop(timeout: 2)
        }
        cpuIsRunning = false
        cpuMetrics = nil
        isRunning = false
        settingsAppliedAtServerStart = nil
    }

    func resetSettings() {
        settings = NativSettings()
    }

    func clearLogs() {
        logText = ""
    }

    func refreshMetricsIfRunning(force: Bool = false) {
        refreshCPUMetricsIfRunning()
        isRunning = server.isRunning
        guard isRunning else {
            stopMetricsPolling(clearSession: true)
            notifyMenuStateChanged()
            return
        }
        guard metricsFetchTask == nil else {
            return
        }
        guard force || metricsAreStale else {
            return
        }

        let client = metricsClient
        let serverAPIKey = settingsAppliedAtServerStart?.serverAPIKey
        metricsFetchTask = Task { [weak self] in
            do {
                let fetchedMetrics = try await client.fetchMetrics(apiKey: serverAPIKey)
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

    private func refreshCPUMetricsIfRunning() {
        cpuIsRunning = cpuServer.isRunning
        guard cpuIsRunning else {
            cpuMetrics = nil
            return
        }
        guard cpuMetricsFetchTask == nil else {
            return
        }

        let client = cpuMetricsClient
        cpuMetricsFetchTask = Task { [weak self] in
            let fetchedMetrics = try? await client.fetchMetrics()
            await MainActor.run {
                self?.cpuMetricsFetchTask = nil
                if let fetchedMetrics {
                    self?.cpuMetrics = fetchedMetrics
                }
            }
        }
    }

    private func configureServerCallbacks() {
        server.onOutput = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                if text.contains("Application startup failed")
                    || text.contains("Failed to load model")
                    || text.contains("not supported") {
                    self.sawModelLoadFailureInOutput = true
                }
                self.appendLog(text)
            }
        }
        cpuServer.onOutput = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.appendLog(text)
            }
        }
        cpuServer.onTermination = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.appendLog("\nCPU mlx-vlm-server stopped with status \(status)\n")
                self?.cpuIsRunning = false
                self?.cpuMetrics = nil
                self?.notifyMenuStateChanged()
            }
        }
        server.onTermination = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.appendLog("\nmlx-vlm-server stopped with status \(status)\n")

                // A model mlx-vlm can't load (unsupported model_type, e.g. an encoder
                // like bert or an unimplemented arch like wave) aborts server startup.
                // Recover once by restarting without pre-loading it, so a bad model
                // selection can't keep the server — and the app — down.
                if self.shouldRecoverFromPreloadFailure(status: status) {
                    let failedModelID = self.settingsAppliedAtServerStart?.languageModelID
                    self.didAttemptPreloadRecovery = true
                    self.isRunning = false
                    self.cpuIsRunning = false
                    self.stopMetricsPolling(clearSession: true)
                    self.metricsLoading = false
                    self.modelPreloadFailureNotice = failedModelID.map {
                        "Couldn’t load \($0). The server is running without a preloaded model — pick another model to try again."
                    } ?? "Couldn’t preload the selected model. The server is running without it."
                    self.appendLog("\nThe configured model failed to load — restarting the server without preloading it.\n")
                    self.startServer(recoveringWithoutPreload: true)
                    return
                }

                self.isRunning = false
                self.settingsAppliedAtServerStart = nil
                self.stopMetricsPolling(clearSession: true)
                self.metricsLoading = false
                if self.isStoppingForModelSwitch != true {
                    self.modelSwitchInProgress = false
                    self.clearPreservedSessionStats()
                }
                self.notifyMenuStateChanged()
            }
        }
    }

    private func startMetricsPolling() {
        lastMetricsError = nil
        metrics = nil
        metricsLoading = true
        sessionTokenActivity = []
        previousSessionPromptTokenCount = nil
        previousSessionGeneratedTokenCount = nil
        metricsStartupGraceUntil = Date().addingTimeInterval(20)

        if metricsTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    self.refreshMetricsIfRunning(force: self.metricsLoading)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            metricsTimer = timer
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.refreshMetricsIfRunning(force: true)
        }
    }

    private func stopMetricsPolling(clearSession: Bool) {
        metricsFetchTask?.cancel()
        metricsFetchTask = nil
        metricsTimer?.invalidate()
        metricsTimer = nil
        lastMetricsError = nil
        lastMetricsFetchAt = nil
        metricsStartupGraceUntil = nil
        metricsLoading = false

        if clearSession {
            metrics = nil
            sessionTokenActivity = []
            previousSessionPromptTokenCount = nil
            previousSessionGeneratedTokenCount = nil
        }
    }

    private func handleMetricsFetchSuccess(_ fetchedMetrics: NativMetrics) {
        metricsFetchTask = nil
        lastMetricsFetchAt = Date()
        guard server.isRunning else {
            isRunning = false
            metrics = nil
            notifyMenuStateChanged()
            return
        }

        isRunning = true
        lastMetricsError = nil
        metricsStartupGraceUntil = nil
        metricsLoading = false
        recordSessionActivity(
            promptTokenCount: fetchedMetrics.summary.promptTokensTotal,
            generatedTokenCount: fetchedMetrics.summary.generatedTokensTotal
        )
        metrics = fetchedMetrics
        modelSwitchInProgress = false
        clearPreservedSessionStats()
        refreshAllTimeStats(runtimePath: fetchedMetrics.server.analyticsDatabasePath)

        if menuIsOpen {
            notifyMenuStateChanged()
        }
    }

    private func handleMetricsFetchFailure(_ error: Error) {
        metricsFetchTask = nil
        lastMetricsError = isTransientStartupMetricsError(error) ? nil : error.localizedDescription

        if !menuIsOpen {
            notifyMenuStateChanged()
        }
    }

    private func isTransientStartupMetricsError(_ error: Error) -> Bool {
        guard let metricsStartupGraceUntil, Date() < metricsStartupGraceUntil else {
            return false
        }
        guard let urlError = error as? URLError else {
            return false
        }

        switch urlError.code {
        case .cannotConnectToHost, .networkConnectionLost, .timedOut:
            return true
        default:
            return false
        }
    }

    private func appendLog(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        let stamp = "[\(Self.logTimestampFormatter.string(from: Date()))] "
        var stamped = ""
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 {
                stamped.append("\n")
                logAtLineStart = true
            }
            if !line.isEmpty {
                if logAtLineStart {
                    stamped.append(stamp)
                }
                stamped.append(line)
                logAtLineStart = false
            }
        }
        logText.append(stamped)
        if logText.count > maxLogCharacters {
            logText.removeFirst(logText.count - maxLogCharacters)
        }
    }

    private func recordSessionActivity(promptTokenCount: Int, generatedTokenCount: Int) {
        let promptDelta = tokenDelta(
            current: promptTokenCount,
            previous: previousSessionPromptTokenCount
        )
        let generatedDelta = tokenDelta(
            current: generatedTokenCount,
            previous: previousSessionGeneratedTokenCount
        )

        sessionTokenActivity.append(SessionTokenActivitySample(
            recordedAt: Date(),
            promptTokens: promptDelta,
            generatedTokens: generatedDelta
        ))
        if sessionTokenActivity.count > maxSessionActivitySamples {
            sessionTokenActivity.removeFirst(sessionTokenActivity.count - maxSessionActivitySamples)
        }
        previousSessionPromptTokenCount = promptTokenCount
        previousSessionGeneratedTokenCount = generatedTokenCount
    }

    private func tokenDelta(current: Int, previous: Int?) -> Int {
        guard let previous, current >= previous else {
            return 0
        }
        return current - previous
    }

    private func preserveCurrentSessionStats() {
        if let metrics {
            preservedSessionMetrics = metrics
            preservedSessionTokenActivity = sessionTokenActivity
        }
    }

    private func clearPreservedSessionStats() {
        preservedSessionMetrics = nil
        preservedSessionTokenActivity = []
    }

    private func refreshAllTimeStats(runtimePath: String? = nil) {
        allTimeStats = NativAllTimeStats.load(
            from: currentAnalyticsDatabaseURL(runtimePath: runtimePath)
        )
    }

    private func currentAnalyticsDatabaseURL(runtimePath: String? = nil) -> URL {
        if let runtimePath = runtimePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !runtimePath.isEmpty {
            return URL(fileURLWithPath: runtimePath).standardizedFileURL
        }
        return NativAnalyticsStore.defaultDatabaseURL()
    }

    private func notifyMenuStateChanged() {
        onMenuStateChanged?()
    }
}
