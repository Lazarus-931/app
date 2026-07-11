import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    struct ModelOption: Identifiable, Hashable, Sendable {
        static let allID = "__all_models__"
        static let all = ModelOption(id: allID, modelID: nil, title: "All")

        let id: String
        let modelID: String?
        let title: String

        var displayTitle: String {
            title == "All" ? title : MLXServerDemoFormatting.truncateModelName(title, maxLength: 52)
        }
    }

    enum RangeOption: String, CaseIterable, Identifiable, Sendable {
        case last24Hours
        case last7Days
        case last30Days
        case allTime

        var id: String { rawValue }

        var title: String {
            switch self {
            case .last24Hours:
                "24 hours"
            case .last7Days:
                "7 days"
            case .last30Days:
                "1 month"
            case .allTime:
                "All time"
            }
        }

        var analyticsRange: MLXServerAnalyticsRange {
            switch self {
            case .last24Hours:
                .last24Hours
            case .last7Days:
                .last7Days
            case .last30Days:
                .last30Days
            case .allTime:
                .allTime
            }
        }

        var defaultGranularity: MLXServerAnalyticsGranularity {
            analyticsRange.granularity
        }

        var preferredBucketCount: Int? {
            switch self {
            case .last24Hours:
                24
            case .last7Days:
                7
            case .last30Days:
                30
            case .allTime:
                nil
            }
        }
    }

    struct BucketPoint: Identifiable, Hashable, Sendable {
        let granularity: MLXServerAnalyticsGranularity
        let bucketStart: Date
        let promptTokensTotal: Int
        let completionTokensTotal: Int
        let generatedTokensTotal: Int
        let requestsStarted: Int
        let requestsCompleted: Int
        let requestsFailed: Int
        let streamingRequests: Int
        let requestTimeTotalMilliseconds: Int64
        let decodeTimeTotalMilliseconds: Int64
        let peakMemoryBytesMax: Int64?

        var id: Date { bucketStart }

        var processedTokensTotal: Int {
            promptTokensTotal + generatedTokensTotal
        }
    }

    @Published private(set) var availableModels: [ModelOption] = [.all]
    @Published private(set) var historicalSummary = MLXServerHistoricalAnalyticsSummary.empty
    @Published private(set) var bucketPoints: [BucketPoint] = []
    @Published private(set) var recentRequestEvents: [MLXServerAnalyticsRequestEvent] = []
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var localModelError: String?
    @Published var selectedModelID: String = ModelOption.allID {
        didSet {
            guard oldValue != selectedModelID else { return }
            reloadHistorical()
        }
    }
    @Published var selectedRange: RangeOption = .last24Hours {
        didSet {
            guard oldValue != selectedRange else { return }
            reloadHistorical()
        }
    }

    private var analyticsDatabaseURL: URL
    private var preferredModelID: String?
    private var hasAppliedPreferredSelection = false
    private var modelScanTask: Task<Void, Never>?
    private var historyLoadTask: Task<DashboardSnapshot, Never>?
    private var historyLoadGeneration = 0

    init(analyticsDatabaseURL: URL = MLXServerAnalyticsStore.defaultDatabaseURL()) {
        self.analyticsDatabaseURL = analyticsDatabaseURL.standardizedFileURL
    }

    deinit {
        modelScanTask?.cancel()
        historyLoadTask?.cancel()
    }

    func updateAnalyticsDatabaseURL(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        guard analyticsDatabaseURL != standardizedURL else {
            return
        }
        analyticsDatabaseURL = standardizedURL
        reloadHistorical()
    }

    func updatePreferredModelID(_ modelID: String?) {
        preferredModelID = normalizedModelID(modelID)
        applyPreferredSelectionIfPossible()
    }

    func scanModels(at path: String) {
        modelScanTask?.cancel()
        localModelError = nil

        modelScanTask = Task { [path] in
            do {
                let models = try await LocalModelDiscovery.scan(path: path)
                guard !Task.isCancelled else {
                    return
                }
                applyScannedModels(models)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                availableModels = [.all]
                localModelError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if selectedModelID != ModelOption.allID {
                    selectedModelID = ModelOption.allID
                }
            }
        }
    }

    func reloadHistorical() {
        historyLoadTask?.cancel()
        isLoadingHistory = true
        historyLoadGeneration += 1

        let databaseURL = analyticsDatabaseURL
        let range = selectedRange
        let selectedModelID = selectedModelID == ModelOption.allID ? nil : selectedModelID
        let generation = historyLoadGeneration

        let task = Task.detached(priority: .userInitiated) {
            let store = MLXServerAnalyticsStore(databaseURL: databaseURL)
            let displayGranularity = Self.displayGranularity(
                for: range,
                store: store,
                modelID: selectedModelID
            )
            let summary = store.fetchSummary(
                range: range.analyticsRange,
                modelID: selectedModelID,
                granularityOverride: displayGranularity
            )
            let rawBuckets = store.fetchBuckets(
                range: range.analyticsRange,
                modelID: selectedModelID,
                granularityOverride: displayGranularity
            )
            let recentRequestEvents = store.fetchRecentRequestEvents(
                range: .allTime,
                modelID: selectedModelID,
                limit: 10
            )
            let points = Self.bucketPoints(
                from: rawBuckets,
                range: range,
                granularity: displayGranularity
            )
            return DashboardSnapshot(
                summary: summary,
                points: points,
                recentRequestEvents: recentRequestEvents
            )
        }
        historyLoadTask = task

        Task { [weak self] in
            guard let self else { return }
            let snapshot = await task.value
            guard !Task.isCancelled else { return }
            guard historyLoadGeneration == generation else { return }
            historicalSummary = snapshot.summary
            bucketPoints = snapshot.points
            recentRequestEvents = snapshot.recentRequestEvents
            isLoadingHistory = false
        }
    }

    private func applyScannedModels(_ models: [LocalModel]) {
        let options = [.all] + models.map {
            ModelOption(id: $0.repoID, modelID: $0.repoID, title: $0.repoID)
        }
        availableModels = options
        localModelError = nil
        applyPreferredSelectionIfPossible()

        guard availableModels.contains(where: { $0.id == selectedModelID }) else {
            selectedModelID = ModelOption.allID
            return
        }
    }

    private func applyPreferredSelectionIfPossible() {
        guard !hasAppliedPreferredSelection else {
            return
        }

        guard let preferredModelID else {
            hasAppliedPreferredSelection = true
            return
        }

        guard availableModels.contains(where: { $0.modelID == preferredModelID }) else {
            return
        }

        hasAppliedPreferredSelection = true
        selectedModelID = preferredModelID
    }

    private func normalizedModelID(_ modelID: String?) -> String? {
        let trimmed = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private extension DashboardViewModel {
    nonisolated static let maximumAllTimeHourlyBucketCount = 72

    struct DashboardSnapshot: Sendable {
        let summary: MLXServerHistoricalAnalyticsSummary
        let points: [BucketPoint]
        let recentRequestEvents: [MLXServerAnalyticsRequestEvent]
    }

    nonisolated static func bucketPoints(
        from rawBuckets: [MLXServerAnalyticsBucketPoint],
        range: RangeOption,
        granularity: MLXServerAnalyticsGranularity,
        calendar: Calendar = .current
    ) -> [BucketPoint] {
        guard !rawBuckets.isEmpty else {
            return []
        }

        let grouped = Dictionary(grouping: rawBuckets, by: \.bucketStart)
        let filledDates = bucketDates(
            from: rawBuckets.map(\.bucketStart),
            range: range,
            granularity: granularity,
            calendar: calendar
        )

        return filledDates.map { bucketStart in
            let rows = grouped[bucketStart] ?? []
            return BucketPoint(
                granularity: rows.first?.granularity ?? granularity,
                bucketStart: bucketStart,
                promptTokensTotal: rows.reduce(0) { $0 + $1.promptTokensTotal },
                completionTokensTotal: rows.reduce(0) { $0 + $1.completionTokensTotal },
                generatedTokensTotal: rows.reduce(0) { $0 + $1.generatedTokensTotal },
                requestsStarted: rows.reduce(0) { $0 + $1.requestsStarted },
                requestsCompleted: rows.reduce(0) { $0 + $1.requestsCompleted },
                requestsFailed: rows.reduce(0) { $0 + $1.requestsFailed },
                streamingRequests: rows.reduce(0) { $0 + $1.streamingRequests },
                requestTimeTotalMilliseconds: rows.reduce(0) { $0 + $1.requestTimeTotalMilliseconds },
                decodeTimeTotalMilliseconds: rows.reduce(0) { $0 + $1.decodeTimeTotalMilliseconds },
                peakMemoryBytesMax: rows.compactMap(\.peakMemoryBytesMax).max()
            )
        }
    }

    nonisolated static func bucketDates(
        from rawDates: [Date],
        range: RangeOption,
        granularity: MLXServerAnalyticsGranularity,
        calendar: Calendar
    ) -> [Date] {
        guard let firstRawDate = rawDates.min(),
              let lastRawDate = rawDates.max()
        else {
            return []
        }

        let end = normalizedBucketDate(
            for: max(lastRawDate, Date()),
            granularity: granularity,
            calendar: calendar
        )

        let dates: [Date]
        if let preferredBucketCount = range.preferredBucketCount {
            let start = offset(
                end,
                by: -(preferredBucketCount - 1),
                granularity: granularity,
                calendar: calendar
            )
            dates = strideDates(
                from: start,
                through: end,
                granularity: granularity,
                calendar: calendar
            )
        } else {
            let start = normalizedBucketDate(
                for: firstRawDate,
                granularity: granularity,
                calendar: calendar
            )
            dates = strideDates(
                from: start,
                through: normalizedBucketDate(
                    for: lastRawDate,
                    granularity: granularity,
                    calendar: calendar
                ),
                granularity: granularity,
                calendar: calendar
            )
        }

        return dates
    }

    nonisolated static func displayGranularity(
        for range: RangeOption,
        store: MLXServerAnalyticsStore,
        modelID: String?,
        calendar: Calendar = .current
    ) -> MLXServerAnalyticsGranularity {
        guard range == .allTime else {
            return range.defaultGranularity
        }

        guard let bounds = store.fetchBucketDateBounds(granularity: .hour, modelID: modelID) else {
            return .day
        }

        let start = normalizedBucketDate(
            for: bounds.start,
            granularity: .hour,
            calendar: calendar
        )
        let end = normalizedBucketDate(
            for: bounds.end,
            granularity: .hour,
            calendar: calendar
        )
        let hourSpan = (calendar.dateComponents([.hour], from: start, to: end).hour ?? 0) + 1

        return hourSpan <= maximumAllTimeHourlyBucketCount ? .hour : .day
    }

    nonisolated static func strideDates(
        from start: Date,
        through end: Date,
        granularity: MLXServerAnalyticsGranularity,
        calendar: Calendar
    ) -> [Date] {
        var dates: [Date] = []
        var current = start
        while current <= end {
            dates.append(current)
            current = offset(current, by: 1, granularity: granularity, calendar: calendar)
        }
        return dates
    }

    nonisolated static func offset(
        _ date: Date,
        by amount: Int,
        granularity: MLXServerAnalyticsGranularity,
        calendar: Calendar
    ) -> Date {
        switch granularity {
        case .hour:
            return calendar.date(byAdding: .hour, value: amount, to: date) ?? date
        case .day:
            return calendar.date(byAdding: .day, value: amount, to: date) ?? date
        }
    }

    nonisolated static func normalizedBucketDate(
        for date: Date,
        granularity: MLXServerAnalyticsGranularity,
        calendar: Calendar
    ) -> Date {
        switch granularity {
        case .hour:
            let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            return calendar.date(from: components) ?? date
        case .day:
            return calendar.startOfDay(for: date)
        }
    }
}
