import Combine
import Foundation
import MLXServerKit

@MainActor
final class MLXServerDemoModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var logText = ""
    @Published private(set) var metrics: MLXServerMetrics?
    @Published private(set) var lastMetricsError: String?
    @Published private(set) var lastMetricsFetchAt: Date?
    @Published private(set) var allTimeStats = MLXServerAllTimeStats.load()

    var menuIsOpen = false
    var onMenuStateChanged: (() -> Void)?

    private let server = MLXServerProcessController()
    private let metricsClient = MLXServerMetricsClient()
    private var metricsFetchTask: Task<Void, Never>?
    private var metricsTimer: Timer?
    private var metricsStartupGraceUntil: Date?
    private var lastPersistedSessionTotals: MLXServerSessionTotals?

    private let maxLogCharacters = 250_000

    init() {
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

    var unavailableMetricsText: String {
        lastMetricsError == nil ? "Waiting for server..." : "Metrics unavailable"
    }

    func startServer() {
        var shouldStartMetrics = false
        do {
            try server.start()
            isRunning = true
            appendLog("\nStarted mlx-vlm-server.\n")
            shouldStartMetrics = true
        } catch MLXServerError.alreadyRunning {
            isRunning = true
            appendLog("\nmlx-vlm-server is already running.\n")
            shouldStartMetrics = true
        } catch {
            appendLog("\nFailed to start mlx-vlm-server: \(error)\n")
        }

        if shouldStartMetrics {
            startMetricsPolling()
        }
        notifyMenuStateChanged()
    }

    func stopServer() {
        do {
            appendLog("\nStopping mlx-vlm-server...\n")
            try server.stop()
        } catch MLXServerError.notRunning {
            appendLog("\nmlx-vlm-server is not running.\n")
        } catch {
            appendLog("\nFailed to stop mlx-vlm-server: \(error)\n")
        }

        isRunning = server.isRunning
        stopMetricsPolling(clearSession: true)
        notifyMenuStateChanged()
    }

    func toggleServer() {
        if isRunning {
            stopServer()
        } else {
            startServer()
        }
    }

    func applicationWillTerminate() {
        stopMetricsPolling(clearSession: true)
        if server.isRunning {
            try? server.stop(timeout: 2)
        }
        isRunning = false
    }

    func refreshMetricsIfRunning(force: Bool = false) {
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

    private func configureServerCallbacks() {
        server.onOutput = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.appendLog(text)
            }
        }
        server.onTermination = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.appendLog("\nmlx-vlm-server stopped with status \(status)\n")
                self?.isRunning = false
                self?.stopMetricsPolling(clearSession: true)
                self?.notifyMenuStateChanged()
            }
        }
    }

    private func startMetricsPolling() {
        lastMetricsError = nil
        metrics = nil
        metricsStartupGraceUntil = Date().addingTimeInterval(20)
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

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
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

        if clearSession {
            metrics = nil
            lastPersistedSessionTotals = nil
        }
    }

    private func handleMetricsFetchSuccess(_ fetchedMetrics: MLXServerMetrics) {
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
        metrics = fetchedMetrics
        persistAllTimeDelta(from: fetchedMetrics.summary)

        if !menuIsOpen {
            notifyMenuStateChanged()
        }
    }

    private func handleMetricsFetchFailure(_ error: Error) {
        metricsFetchTask = nil
        lastMetricsFetchAt = Date()
        lastMetricsError = isTransientStartupMetricsError(error) ? nil : error.localizedDescription
        metrics = nil

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
        logText.append(text)
        if logText.count > maxLogCharacters {
            logText.removeFirst(logText.count - maxLogCharacters)
        }
    }

    private func notifyMenuStateChanged() {
        onMenuStateChanged?()
    }
}
