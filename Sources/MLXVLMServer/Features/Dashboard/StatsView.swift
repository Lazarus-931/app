import Charts
import MLXServerKit
import SwiftUI

struct StatsView: View {
    @ObservedObject var model: MLXServerModel
    let dashboard: DashboardViewModel

    var body: some View {
        DashboardContentView(
            modelState: DashboardModelState(model: model),
            dashboard: dashboard
        )
        .equatable()
    }

    private var sessionSubtitle: String? {
        if let _ = model.metrics {
            return nil
        }
        if model.isRunning {
            return model.unavailableMetricsText
        }
        return "Server is off. Live metrics are paused."
    }

    private var sessionCards: [SessionCardValue] {
        let metrics = model.metrics

        return [
            makeSessionCard(
                title: "Processed tokens",
                rawCount: metrics?.summary.totalProcessedTokens
            ),
            makeSessionCard(
                title: "Prompt tokens",
                rawCount: metrics?.summary.promptTokensTotal
            ),
            makeSessionCard(
                title: "Generated tokens",
                rawCount: metrics?.summary.generatedTokensTotal
            ),
            makeSessionCard(
                title: "Completed requests",
                rawCount: metrics?.summary.requestsCompleted
            ),
            SessionCardValue(
                title: "Decode speed",
                value: MLXServerFormatting.rate(
                    metrics?.summary.averageDecodeTokensPerSecond
                ),
                help: nil
            ),
            SessionCardValue(
                title: "Request speed",
                value: MLXServerFormatting.rate(
                    metrics?.summary.averageRequestTokensPerSecond
                ),
                help: nil
            ),
            SessionCardValue(
                title: "Server uptime",
                value: MLXServerFormatting.duration(metrics?.summary.uptimeSeconds),
                help: nil
            ),
        ]
    }

    private func makeSessionCard(title: String, rawCount: Int?) -> SessionCardValue {
        guard let rawCount else {
            return SessionCardValue(title: title, value: "--", help: nil)
        }
        let formatted = MLXServerFormatting.compactCount(rawCount)
        return SessionCardValue(
            title: title,
            value: formatted.display,
            help: formatted.tooltip
        )
    }
}

private struct DashboardModelState: Equatable {
    let isRunning: Bool
    let modelSearchPath: String
    let analyticsDatabaseURL: URL
    let loadedModelID: String?
    let historicalMetricsRevision: DashboardMetricsRevision?

    @MainActor
    init(model: MLXServerModel) {
        isRunning = model.isRunning
        modelSearchPath = model.settings.modelSearchPath
        analyticsDatabaseURL = model.analyticsDatabaseURL
        loadedModelID = model.metrics?.server.loadedModel
        historicalMetricsRevision = model.metrics.map {
            DashboardMetricsRevision(
                completedRequests: $0.summary.requestsCompleted,
                failedRequests: $0.summary.requestsFailed
            )
        }
    }
}

private struct DashboardContentView: View, Equatable {
    let modelState: DashboardModelState
    @ObservedObject var dashboard: DashboardViewModel
    @FocusState private var isModelSearchFocused: Bool
    @State private var selectedChartMetric: DashboardOverviewMetric = .tokens

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.modelState == rhs.modelState && lhs.dashboard === rhs.dashboard
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader
                filterBar
                overviewCards
                analyticsGrid
                modelPerformanceSection
                recentRequestsSection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: 1500, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture {
            isModelSearchFocused = false
        }
        .onAppear {
            syncDashboardState(scanModels: true, reloadHistory: true)
        }
        .onChange(of: modelState.modelSearchPath) { _, _ in
            syncDashboardState(scanModels: true, reloadHistory: false)
        }
        .onChange(of: modelState.analyticsDatabaseURL) { _, _ in
            syncDashboardState(scanModels: false, reloadHistory: false)
        }
        .onChange(of: modelState.loadedModelID) { _, _ in
            syncDashboardState(scanModels: false, reloadHistory: false)
        }
        .onChange(of: modelState.historicalMetricsRevision) { oldRevision, newRevision in
            guard oldRevision != nil, newRevision != nil else { return }
            syncDashboardState(scanModels: false, reloadHistory: true)
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Analytics")
                    .font(.title2.weight(.semibold))
                Text("Monitor token consumption, request volume, and model performance across this workspace.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Circle()
                    .fill(modelState.isRunning ? DashboardPalette.positive : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(modelState.isRunning ? "Live" : "Offline")
                    .font(.caption.weight(.semibold))

                Button {
                    dashboard.reloadHistorical()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .help("Refresh analytics")
                .disabled(dashboard.isLoadingHistory)
            }
            .fixedSize()
        }
    }

    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                filtersRow
                Spacer(minLength: 16)
                Text(lastUpdatedLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 10) {
                filtersRow
                Text(lastUpdatedLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .dashboardPanelStyle(cornerRadius: 12)
    }

    private var overviewCards: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280), spacing: 14)],
            alignment: .leading,
            spacing: 14
        ) {
            AnalyticsMetricCard(
                title: "Total tokens",
                value: compact(dashboard.historicalSummary.totalProcessedTokens),
                detail: "\(compact(dashboard.historicalSummary.promptTokensTotal)) input · \(compact(dashboard.historicalSummary.generatedTokensTotal)) output",
                icon: "number",
                tint: DashboardPalette.accent,
                isSelected: selectedChartMetric == .tokens
            ) {
                selectedChartMetric = .tokens
            }
            AnalyticsMetricCard(
                title: "Requests",
                value: compact(totalRequests),
                detail: "\(compact(dashboard.historicalSummary.requestsCompleted)) completed",
                icon: "arrow.up.arrow.down",
                tint: DashboardPalette.indigo,
                isSelected: selectedChartMetric == .requests
            ) {
                selectedChartMetric = .requests
            }
            AnalyticsMetricCard(
                title: "Success rate",
                value: successRateLabel,
                detail: dashboard.historicalSummary.requestsFailed == 0
                    ? "No failed requests"
                    : "\(compact(dashboard.historicalSummary.requestsFailed)) failed",
                icon: "checkmark.circle",
                tint: DashboardPalette.positive,
                isSelected: selectedChartMetric == .successRate
            ) {
                selectedChartMetric = .successRate
            }
            AnalyticsMetricCard(
                title: "Decode speed",
                value: MLXServerFormatting.rate(
                    dashboard.historicalSummary.averageDecodeTokensPerSecond
                ),
                detail: "Average across requests",
                icon: "gauge.with.dots.needle.67percent",
                tint: DashboardPalette.orange,
                isSelected: selectedChartMetric == .decodeSpeed
            ) {
                selectedChartMetric = .decodeSpeed
            }
        }
    }

    private var analyticsGrid: some View {
        TokenUsagePanel(
            metric: selectedChartMetric,
            points: dashboard.bucketPoints,
            modelPoints: dashboard.modelTokenPoints,
            range: dashboard.selectedRange,
            showsAllModels: dashboard.appliedModelID == DashboardViewModel.ModelOption.allID
        )
        .frame(maxWidth: .infinity)
    }

    private var modelPerformanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            AnalyticsSectionHeader(
                title: "Model performance",
                subtitle: "Usage and throughput by model for the selected period"
            )

            ModelPerformanceTable(
                rows: dashboard.modelPerformance,
                modelColorDomain: chartModelColorDomain,
                searchFocus: $isModelSearchFocused
            )

            if let localModelError = dashboard.localModelError {
                Text(localModelError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recentRequestsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            AnalyticsSectionHeader(
                title: "Recent requests",
                subtitle: "Select a request to inspect latency, throughput, and memory details"
            )

            DashboardRecentRequestsTable(requests: dashboard.recentRequestEvents)
        }
    }

    private var leadingModelIDs: [String] {
        Array(dashboard.modelPerformance.prefix(modelOverviewLimit).map(\.modelID))
    }

    private var chartModelColorDomain: [String] {
        var modelIDs = leadingModelIDs
        if dashboard.modelPerformance.count > modelOverviewLimit {
            modelIDs.append("Other")
        }
        return DashboardModelColorScale.domain(for: modelIDs)
    }

    private var modelOverviewLimit: Int { 12 }

    private var totalRequests: Int {
        dashboard.historicalSummary.requestsCompleted + dashboard.historicalSummary.requestsFailed
    }

    private var successRateLabel: String {
        guard totalRequests > 0 else { return "--" }
        return MLXServerFormatting.percent(
            Double(dashboard.historicalSummary.requestsCompleted) / Double(totalRequests)
        )
    }

    private var lastUpdatedLabel: String {
        guard let date = dashboard.historicalSummary.lastUpdatedAt else {
            return dashboard.isLoadingHistory ? "Refreshing…" : "Waiting for analytics data"
        }
        return "Updated \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func compact(_ value: Int) -> String {
        MLXServerFormatting.compactCount(value).display
    }

    private var filtersRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                modelFilter.frame(width: 300)
                periodFilter.frame(width: 430)
            }

            VStack(alignment: .leading, spacing: 10) {
                modelFilter.frame(maxWidth: .infinity)
                periodFilter.frame(maxWidth: .infinity)
            }
        }
    }

    private var modelFilter: some View {
        DashboardPickerContainer(title: "Model") {
            Picker("Model", selection: $dashboard.selectedModelID) {
                ForEach(dashboard.availableModels) { option in
                    Text(option.displayTitle).tag(option.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var periodFilter: some View {
        DashboardPickerContainer(title: "Period") {
            DashboardPeriodSelector(selection: $dashboard.selectedRange)
        }
    }

    private func syncDashboardState(scanModels: Bool, reloadHistory: Bool) {
        dashboard.updateAnalyticsDatabaseURL(modelState.analyticsDatabaseURL)
        dashboard.updatePreferredModelID(modelState.loadedModelID)
        if scanModels {
            dashboard.scanModels(at: modelState.modelSearchPath)
        }
        if reloadHistory {
            dashboard.reloadHistorical()
        }
    }
}

private struct DashboardMetricsRevision: Equatable {
    let completedRequests: Int
    let failedRequests: Int
}

private struct AnalyticsSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AnalyticsMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: icon)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    Image(systemName: isSelected ? "checkmark" : "arrow.up.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(
                            isSelected || isHovered
                                ? tint
                                : Color.secondary.opacity(0.5)
                        )
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 25, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(16)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .dashboardPanelStyle(cornerRadius: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isHovered ? tint.opacity(0.045) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected ? tint : (isHovered ? tint.opacity(0.55) : Color.clear),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.012 : 1)
        .shadow(
            color: isHovered ? tint.opacity(0.14) : Color.clear,
            radius: isHovered ? 9 : 0,
            y: isHovered ? 4 : 0
        )
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { isHovered = $0 }
        .help("Show \(title.lowercased()) chart")
        .accessibilityValue(isSelected ? "Selected" : "Select to update chart")
    }
}

private enum DashboardOverviewMetric: String {
    case tokens
    case requests
    case successRate
    case decodeSpeed
}

private struct TokenUsagePanel: View {
    struct HistogramSegment: Identifiable {
        let modelID: String
        let bucketStart: Date
        let yStart: Int
        let yEnd: Int

        var id: String { "\(modelID):\(bucketStart.timeIntervalSince1970)" }
    }

    struct RequestHistogramSegment: Identifiable {
        let bucketStart: Date
        let status: String
        let yStart: Int
        let yEnd: Int
        let color: Color

        var id: String { "\(status):\(bucketStart.timeIntervalSince1970)" }
    }

    struct ModelRequestHistogramSegment: Identifiable {
        let modelID: String
        let bucketStart: Date
        let yStart: Int
        let yEnd: Int

        var id: String { "\(modelID):\(bucketStart.timeIntervalSince1970)" }
    }

    enum AllModelsDisplay: String, CaseIterable, Identifiable {
        case lines = "Lines"
        case stacked = "Histogram"

        var id: String { rawValue }
    }

    let metric: DashboardOverviewMetric
    let points: [DashboardViewModel.BucketPoint]
    let modelPoints: [DashboardViewModel.ModelTokenPoint]
    let range: DashboardViewModel.RangeOption
    let showsAllModels: Bool
    @State private var hoveredPointID: Date?
    @State private var allModelsDisplay: AllModelsDisplay = .lines

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                AnalyticsSectionHeader(
                    title: chartTitle,
                    subtitle: chartSubtitle
                )
                Spacer()
                if metric == .tokens && showsAllModels {
                    Picker("Chart display", selection: $allModelsDisplay) {
                        ForEach(AllModelsDisplay.allCases) { display in
                            Text(display.rawValue).tag(display)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                } else if metric == .successRate || !showsAllModels {
                    chartLegend
                }
            }

            if points.isEmpty {
                DashboardEmptyChart()
                    .frame(minHeight: 230)
            } else if metric == .successRate {
                SuccessRateHealthChart(
                    points: points,
                    modelPoints: modelPoints,
                    range: range,
                    showsAllModels: showsAllModels
                )
            } else {
                Chart {
                    usageMarks
                    hoverMarks
                }
                .chartLegend(showsAllModels ? .visible : .hidden)
                .chartForegroundStyleScale(
                    domain: modelColorDomain,
                    range: DashboardModelColorScale.colors(for: modelColorDomain)
                )
                .chartXAxis {
                    AxisMarks(values: axisDates) { value in
                        AxisGridLine().foregroundStyle(DashboardPalette.axisGrid)
                        AxisTick().foregroundStyle(DashboardPalette.axisTick)
                        if let date = value.as(Date.self) {
                            AxisValueLabel(axisLabel(for: date))
                                .font(.caption2)
                                .foregroundStyle(DashboardPalette.axisText)
                        }
                    }
                }
                .chartYAxis {
                    if metric == .successRate {
                        AxisMarks(position: .leading, values: [0.0, 0.25, 0.5, 0.75, 1.0]) { value in
                            AxisGridLine().foregroundStyle(DashboardPalette.axisGrid)
                            AxisTick().foregroundStyle(DashboardPalette.axisTick)
                            if let raw = value.as(Double.self) {
                                AxisValueLabel(yAxisLabel(for: raw))
                                    .font(.caption2)
                                    .foregroundStyle(DashboardPalette.axisText)
                            }
                        }
                    } else {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                            AxisGridLine().foregroundStyle(DashboardPalette.axisGrid)
                            AxisTick().foregroundStyle(DashboardPalette.axisTick)
                            if let raw = value.as(Double.self) {
                                AxisValueLabel(yAxisLabel(for: raw))
                                    .font(.caption2)
                                    .foregroundStyle(DashboardPalette.axisText)
                            }
                        }
                    }
                }
                .chartYScale(domain: yDomain)
                .frame(height: 250)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        updateHoveredPoint(
                                            at: location,
                                            proxy: proxy,
                                            geometry: geometry
                                        )
                                    case .ended:
                                        hoveredPointID = nil
                                    }
                                }

                            if let hoveredPoint,
                               let tooltipCenter = tooltipCenter(
                                   for: hoveredPoint,
                                   proxy: proxy,
                                   geometry: geometry
                               ) {
                                Group {
                                    if metric == .tokens && showsAllModels {
                                        ModelTokenUsageTooltip(
                                            date: hoveredPoint.bucketStart,
                                            points: modelValues(at: hoveredPoint.bucketStart),
                                            granularity: granularity
                                        )
                                    } else if showsAllModels {
                                        ModelOverviewTooltip(
                                            metric: metric,
                                            date: hoveredPoint.bucketStart,
                                            points: tooltipModelValues(at: hoveredPoint.bucketStart),
                                            granularity: granularity
                                        )
                                    } else if metric == .tokens {
                                        TokenUsageTooltip(point: hoveredPoint, granularity: granularity)
                                    } else {
                                        DashboardMetricTooltip(
                                            metric: metric,
                                            point: hoveredPoint,
                                            granularity: granularity
                                        )
                                    }
                                }
                                .position(tooltipCenter)
                                .allowsHitTesting(false)
                                .transition(.identity)
                            }
                        }
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                    }
                }
                .onChange(of: points) { _, newPoints in
                    if let hoveredPointID,
                       !newPoints.contains(where: { $0.id == hoveredPointID }) {
                        self.hoveredPointID = nil
                    }
                }
                .onChange(of: metric) { _, _ in
                    hoveredPointID = nil
                }
                .animation(.easeInOut(duration: 0.2), value: metric)
            }
        }
        .padding(18)
        .dashboardPanelStyle(cornerRadius: 14)
    }

    private var chartTitle: String {
        switch metric {
        case .tokens:
            "Token usage"
        case .requests:
            "Requests"
        case .successRate:
            "Success rate"
        case .decodeSpeed:
            "Decode speed"
        }
    }

    private var chartSubtitle: String {
        switch metric {
        case .tokens:
            showsAllModels ? "Total tokens by model over time" : "Input and output tokens over time"
        case .requests:
            showsAllModels
                ? "Total requests by model over time"
                : "Completed and failed requests over time"
        case .successRate:
            showsAllModels
                ? "Request reliability timeline by model"
                : "Request reliability across the selected period"
        case .decodeSpeed:
            showsAllModels
                ? "Decode speed by model over time"
                : "Generated tokens per second over time"
        }
    }

    @ViewBuilder
    private var chartLegend: some View {
        HStack(spacing: 14) {
            switch metric {
            case .tokens:
                ChartLegendDot(color: DashboardPalette.accent, title: "Input")
                ChartLegendDot(color: DashboardPalette.indigo, title: "Output")
            case .requests:
                ChartLegendDot(color: DashboardPalette.positive, title: "Completed")
                ChartLegendDot(color: DashboardPalette.negative, title: "Failed")
            case .successRate:
                ChartLegendDot(color: DashboardPalette.positive, title: "Healthy")
                ChartLegendDot(color: DashboardPalette.orange, title: "Degraded")
                ChartLegendDot(color: DashboardPalette.negative, title: "Failed")
                ChartLegendDot(color: Color.secondary.opacity(0.35), title: "No requests")
            case .decodeSpeed:
                ChartLegendDot(color: DashboardPalette.orange, title: "Tokens/s")
            }
        }
    }

    @ChartContentBuilder
    private var usageMarks: some ChartContent {
        switch metric {
        case .tokens:
            if showsAllModels {
                allModelMarks
            } else {
                inputOutputMarks
            }
        case .requests:
            if showsAllModels {
                allModelRequestMarks
            } else {
                requestMarks
            }
        case .successRate:
            if showsAllModels {
                allModelSuccessRateMarks
            } else {
                successRateMarks
            }
        case .decodeSpeed:
            if showsAllModels {
                allModelDecodeSpeedMarks
            } else {
                decodeSpeedMarks
            }
        }
    }

    @ChartContentBuilder
    private var allModelMarks: some ChartContent {
        if allModelsDisplay == .lines {
            ForEach(modelPoints) { point in
                LineMark(
                    x: .value("Time", point.bucketStart),
                    y: .value("Total tokens", Double(point.totalTokens)),
                    series: .value("Model", point.modelID)
                )
                .foregroundStyle(by: .value("Model", point.modelID))
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
            }
        } else {
            ForEach(histogramSegments) { segment in
                RectangleMark(
                    xStart: .value("Bucket start", segment.bucketStart),
                    xEnd: .value("Bucket end", bucketEnd(after: segment.bucketStart)),
                    yStart: .value("Token start", Double(segment.yStart)),
                    yEnd: .value("Token end", Double(segment.yEnd))
                )
                .foregroundStyle(by: .value("Model", segment.modelID))
                .opacity(0.9)
            }
        }
    }

    @ChartContentBuilder
    private var inputOutputMarks: some ChartContent {
        ForEach(points) { point in
            AreaMark(
                x: .value("Time", point.bucketStart),
                yStart: .value("Baseline", 0.0),
                yEnd: .value("Input tokens", Double(point.promptTokensTotal))
            )
            .foregroundStyle(
                .linearGradient(
                    colors: [DashboardPalette.accent.opacity(0.28), DashboardPalette.accent.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Time", point.bucketStart),
                y: .value("Input tokens", Double(point.promptTokensTotal)),
                series: .value("Series", "Input")
            )
            .foregroundStyle(DashboardPalette.accent)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Time", point.bucketStart),
                y: .value("Output tokens", Double(point.generatedTokensTotal)),
                series: .value("Series", "Output")
            )
            .foregroundStyle(DashboardPalette.indigo)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder
    private var requestMarks: some ChartContent {
        ForEach(requestHistogramSegments) { segment in
            RectangleMark(
                xStart: .value("Bucket start", segment.bucketStart),
                xEnd: .value("Bucket end", bucketEnd(after: segment.bucketStart)),
                yStart: .value("Request start", Double(segment.yStart)),
                yEnd: .value("Request end", Double(segment.yEnd))
            )
            .foregroundStyle(segment.color.gradient)
            .opacity(
                hoveredPointID == nil || hoveredPointID == segment.bucketStart
                    ? 0.92
                    : 0.35
            )
        }
    }

    @ChartContentBuilder
    private var allModelRequestMarks: some ChartContent {
        ForEach(modelRequestHistogramSegments) { segment in
            RectangleMark(
                xStart: .value("Bucket start", segment.bucketStart),
                xEnd: .value("Bucket end", bucketEnd(after: segment.bucketStart)),
                yStart: .value("Request start", Double(segment.yStart)),
                yEnd: .value("Request end", Double(segment.yEnd))
            )
            .foregroundStyle(by: .value("Model", segment.modelID))
            .opacity(
                hoveredPointID == nil || hoveredPointID == segment.bucketStart
                    ? 0.92
                    : 0.35
            )
        }
    }

    @ChartContentBuilder
    private var successRateMarks: some ChartContent {
        ForEach(successRatePoints) { point in
            let successRate = successRate(for: point) ?? 0
            BarMark(
                x: .value("Time", point.bucketStart),
                yStart: .value("Success start", 0.0),
                yEnd: .value("Success end", successRate),
                width: .ratio(0.68)
            )
            .foregroundStyle(DashboardPalette.positive.gradient)
            .opacity(
                hoveredPointID == nil || hoveredPointID == point.bucketStart
                    ? 0.94
                    : 0.35
            )
            .cornerRadius(2)

            BarMark(
                x: .value("Time", point.bucketStart),
                yStart: .value("Failure start", successRate),
                yEnd: .value("Failure end", 1.0),
                width: .ratio(0.68)
            )
            .foregroundStyle(DashboardPalette.negative.gradient)
            .opacity(
                hoveredPointID == nil || hoveredPointID == point.bucketStart
                    ? 0.94
                    : 0.35
            )
            .cornerRadius(2)
        }
    }

    @ChartContentBuilder
    private var allModelSuccessRateMarks: some ChartContent {
        ForEach(modelSuccessRatePoints) { point in
            BarMark(
                x: .value("Time", point.bucketStart),
                yStart: .value("Success start", 0.0),
                yEnd: .value("Success end", point.successRate ?? 0)
            )
            .foregroundStyle(by: .value("Model", point.modelID))
            .position(by: .value("Model", point.modelID))
            .opacity(
                hoveredPointID == nil || hoveredPointID == point.bucketStart
                    ? 0.94
                    : 0.35
            )
            .cornerRadius(2)

            BarMark(
                x: .value("Time", point.bucketStart),
                yStart: .value("Failure start", point.successRate ?? 0),
                yEnd: .value("Failure end", 1.0)
            )
            .foregroundStyle(by: .value("Model", point.modelID))
            .position(by: .value("Model", point.modelID))
            .opacity(
                hoveredPointID == nil || hoveredPointID == point.bucketStart
                    ? 0.22
                    : 0.08
            )
            .cornerRadius(2)
        }
    }

    @ChartContentBuilder
    private var decodeSpeedMarks: some ChartContent {
        ForEach(points) { point in
            let decodeSpeed = decodeSpeed(for: point) ?? 0
            AreaMark(
                x: .value("Time", point.bucketStart),
                yStart: .value("Baseline", 0.0),
                yEnd: .value("Decode speed", decodeSpeed)
            )
            .foregroundStyle(
                .linearGradient(
                    colors: [DashboardPalette.orange.opacity(0.25), DashboardPalette.orange.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Time", point.bucketStart),
                y: .value("Decode speed", decodeSpeed)
            )
            .foregroundStyle(DashboardPalette.orange)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder
    private var allModelDecodeSpeedMarks: some ChartContent {
        ForEach(modelPoints) { point in
            LineMark(
                x: .value("Time", point.bucketStart),
                y: .value("Decode speed", point.decodeSpeed ?? 0),
                series: .value("Model", point.modelID)
            )
            .foregroundStyle(by: .value("Model", point.modelID))
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder
    private var hoverMarks: some ChartContent {
        if let hoveredPoint {
            RuleMark(x: .value("Selected time", hoverDate(for: hoveredPoint)))
                .foregroundStyle(DashboardPalette.axisLabel.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            switch metric {
            case .tokens:
                if showsAllModels {
                    ForEach(modelValues(at: hoveredPoint.bucketStart)) { modelPoint in
                        PointMark(
                            x: .value("Selected time", modelPoint.bucketStart),
                            y: .value("Total tokens", Double(modelPoint.totalTokens))
                        )
                        .foregroundStyle(by: .value("Model", modelPoint.modelID))
                        .symbolSize(42)
                    }
                } else {
                    PointMark(
                        x: .value("Selected time", hoveredPoint.bucketStart),
                        y: .value("Input tokens", Double(hoveredPoint.promptTokensTotal))
                    )
                    .foregroundStyle(DashboardPalette.accent)
                    .symbolSize(48)

                    PointMark(
                        x: .value("Selected time", hoveredPoint.bucketStart),
                        y: .value("Output tokens", Double(hoveredPoint.generatedTokensTotal))
                    )
                    .foregroundStyle(DashboardPalette.indigo)
                    .symbolSize(48)
                }
            case .requests:
                if showsAllModels {
                    ForEach(modelRequestSegments(at: hoveredPoint.bucketStart)) { segment in
                        PointMark(
                            x: .value("Selected time", hoverDate(for: hoveredPoint)),
                            y: .value("Requests", Double(segment.yEnd))
                        )
                        .foregroundStyle(by: .value("Model", segment.modelID))
                        .symbolSize(48)
                    }
                } else {
                    if hoveredPoint.requestsCompleted > 0 {
                        PointMark(
                            x: .value("Selected time", hoverDate(for: hoveredPoint)),
                            y: .value("Completed", Double(hoveredPoint.requestsCompleted))
                        )
                        .foregroundStyle(DashboardPalette.positive)
                        .symbolSize(48)
                    }

                    if hoveredPoint.requestsFailed > 0 {
                        PointMark(
                            x: .value("Selected time", hoverDate(for: hoveredPoint)),
                            y: .value(
                                "Total requests",
                                Double(hoveredPoint.requestsCompleted + hoveredPoint.requestsFailed)
                            )
                        )
                        .foregroundStyle(DashboardPalette.negative)
                        .symbolSize(48)
                    }
                }
            case .successRate:
                RuleMark(y: .value("Success baseline", 0.0))
                    .foregroundStyle(Color.clear)
            case .decodeSpeed:
                if showsAllModels {
                    ForEach(modelValues(at: hoveredPoint.bucketStart)) { modelPoint in
                        PointMark(
                            x: .value("Selected time", modelPoint.bucketStart),
                            y: .value("Decode speed", modelPoint.decodeSpeed ?? 0)
                        )
                        .foregroundStyle(by: .value("Model", modelPoint.modelID))
                        .symbolSize(48)
                    }
                } else {
                    PointMark(
                        x: .value("Selected time", hoveredPoint.bucketStart),
                        y: .value("Decode speed", decodeSpeed(for: hoveredPoint) ?? 0)
                    )
                    .foregroundStyle(DashboardPalette.orange)
                    .symbolSize(48)
                }
            }
        }
    }

    private var hoveredPoint: DashboardViewModel.BucketPoint? {
        guard let hoveredPointID else { return nil }
        return points.first { $0.id == hoveredPointID }
    }

    private var granularity: MLXServerAnalyticsGranularity {
        points.first?.granularity ?? (range == .last24Hours ? .hour : .day)
    }

    private var axisDates: [Date] {
        DashboardChartAxis.markDates(from: points.map(\.bucketStart), maximumCount: 6)
    }

    private var modelColorDomain: [String] {
        DashboardModelColorScale.domain(for: modelPoints.map(\.modelID))
    }

    private var successRatePoints: [DashboardViewModel.BucketPoint] {
        points.filter { $0.requestsCompleted + $0.requestsFailed > 0 }
    }

    private var modelSuccessRatePoints: [DashboardViewModel.ModelTokenPoint] {
        modelPoints.filter { $0.totalRequests > 0 }
    }

    private var yDomain: ClosedRange<Double> {
        if metric == .successRate {
            return 0...1
        }

        let maximum: Double
        switch metric {
        case .tokens where showsAllModels && allModelsDisplay == .stacked:
            maximum = Dictionary(grouping: modelPoints, by: \.bucketStart)
                .values
                .map { points in Double(points.reduce(0) { $0 + $1.totalTokens }) }
                .max() ?? 0
        case .tokens where showsAllModels:
            maximum = Double(modelPoints.map(\.totalTokens).max() ?? 0)
        case .tokens:
            maximum = Double(points.map { max($0.promptTokensTotal, $0.generatedTokensTotal) }.max() ?? 0)
        case .requests:
            maximum = Double(
                points.map { $0.requestsCompleted + $0.requestsFailed }.max() ?? 0
            )
        case .successRate:
            maximum = 1
        case .decodeSpeed:
            maximum = showsAllModels
                ? modelPoints.compactMap(\.decodeSpeed).max() ?? 0
                : points.compactMap(decodeSpeed(for:)).max() ?? 0
        }

        return 0...max(maximum * 1.1, 1)
    }

    private func yAxisLabel(for value: Double) -> String {
        switch metric {
        case .tokens, .requests:
            MLXServerFormatting.compactCount(Int(value.rounded())).display
        case .successRate:
            MLXServerFormatting.percent(value)
        case .decodeSpeed:
            value == 0 ? "0 tok/s" : MLXServerFormatting.rate(value)
        }
    }

    private func successRate(for point: DashboardViewModel.BucketPoint) -> Double? {
        let total = point.requestsCompleted + point.requestsFailed
        guard total > 0 else { return nil }
        return Double(point.requestsCompleted) / Double(total)
    }

    private func decodeSpeed(for point: DashboardViewModel.BucketPoint) -> Double? {
        guard point.generatedTokensTotal > 0, point.decodeTimeTotalMilliseconds > 0 else {
            return nil
        }
        return Double(point.generatedTokensTotal) / (Double(point.decodeTimeTotalMilliseconds) / 1_000)
    }

    private func modelValues(at date: Date) -> [DashboardViewModel.ModelTokenPoint] {
        modelPoints
            .filter { $0.bucketStart == date }
            .sorted { modelValue(for: $0) > modelValue(for: $1) }
    }

    private func successModelValues(at date: Date) -> [DashboardViewModel.ModelTokenPoint] {
        modelValues(at: date).filter { $0.totalRequests > 0 }
    }

    private func modelValue(for point: DashboardViewModel.ModelTokenPoint) -> Double {
        switch metric {
        case .tokens:
            Double(point.totalTokens)
        case .requests:
            Double(point.totalRequests)
        case .successRate:
            point.successRate ?? 0
        case .decodeSpeed:
            point.decodeSpeed ?? 0
        }
    }

    private var histogramSegments: [HistogramSegment] {
        Dictionary(grouping: modelPoints, by: \.bucketStart)
            .flatMap { bucketStart, bucketPoints in
                var cumulative = 0
                return bucketPoints
                    .sorted { $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending }
                    .map { point in
                        let segment = HistogramSegment(
                            modelID: point.modelID,
                            bucketStart: bucketStart,
                            yStart: cumulative,
                            yEnd: cumulative + point.totalTokens
                        )
                        cumulative += point.totalTokens
                        return segment
                    }
            }
            .sorted {
                if $0.bucketStart == $1.bucketStart { return $0.yStart < $1.yStart }
                return $0.bucketStart < $1.bucketStart
            }
    }

    private var requestHistogramSegments: [RequestHistogramSegment] {
        points.flatMap { point in
            var segments: [RequestHistogramSegment] = []
            if point.requestsCompleted > 0 {
                segments.append(
                    RequestHistogramSegment(
                        bucketStart: point.bucketStart,
                        status: "Completed",
                        yStart: 0,
                        yEnd: point.requestsCompleted,
                        color: DashboardPalette.positive
                    )
                )
            }
            if point.requestsFailed > 0 {
                segments.append(
                    RequestHistogramSegment(
                        bucketStart: point.bucketStart,
                        status: "Failed",
                        yStart: point.requestsCompleted,
                        yEnd: point.requestsCompleted + point.requestsFailed,
                        color: DashboardPalette.negative
                    )
                )
            }
            return segments
        }
    }

    private var modelRequestHistogramSegments: [ModelRequestHistogramSegment] {
        Dictionary(grouping: modelPoints, by: \.bucketStart)
            .flatMap { bucketStart, bucketPoints in
                var cumulative = 0
                return bucketPoints
                    .sorted { $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending }
                    .compactMap { point -> ModelRequestHistogramSegment? in
                        guard point.totalRequests > 0 else { return nil }
                        let segment = ModelRequestHistogramSegment(
                            modelID: point.modelID,
                            bucketStart: bucketStart,
                            yStart: cumulative,
                            yEnd: cumulative + point.totalRequests
                        )
                        cumulative += point.totalRequests
                        return segment
                    }
            }
            .sorted {
                if $0.bucketStart == $1.bucketStart { return $0.yStart < $1.yStart }
                return $0.bucketStart < $1.bucketStart
            }
    }

    private func modelRequestSegments(at date: Date) -> [ModelRequestHistogramSegment] {
        modelRequestHistogramSegments.filter { $0.bucketStart == date }
    }

    private func bucketEnd(after date: Date) -> Date {
        switch granularity {
        case .hour:
            Calendar.current.date(byAdding: .hour, value: 1, to: date) ?? date.addingTimeInterval(3_600)
        case .day:
            Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        }
    }

    private func axisLabel(for date: Date) -> String {
        DashboardChartAxis.label(
            for: date,
            granularity: granularity,
            range: range
        )
    }

    private func updateHoveredPoint(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrameAnchor = proxy.plotFrame else {
            hoveredPointID = nil
            return
        }

        let plotFrame = geometry[plotFrameAnchor]
        guard plotFrame.contains(location) else {
            hoveredPointID = nil
            return
        }

        let plotX = location.x - plotFrame.minX
        guard let hoveredDate: Date = proxy.value(atX: plotX) else {
            hoveredPointID = nil
            return
        }

        let nextPoint: DashboardViewModel.BucketPoint?
        if metric == .requests {
            nextPoint = points.first {
                hoveredDate >= $0.bucketStart && hoveredDate < bucketEnd(after: $0.bucketStart)
            }
        } else if metric == .successRate {
            nextPoint = successRatePoints.min {
                abs($0.bucketStart.timeIntervalSince(hoveredDate))
                    < abs($1.bucketStart.timeIntervalSince(hoveredDate))
            }
        } else {
            nextPoint = points.min {
                abs($0.bucketStart.timeIntervalSince(hoveredDate))
                    < abs($1.bucketStart.timeIntervalSince(hoveredDate))
            }
        }
        guard hoveredPointID != nextPoint?.id else { return }
        hoveredPointID = nextPoint?.id
    }

    private func tooltipCenter(
        for point: DashboardViewModel.BucketPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> CGPoint? {
        guard let plotFrameAnchor = proxy.plotFrame,
              let plotX = proxy.position(forX: hoverDate(for: point)),
              let plotY = proxy.position(forY: tooltipAnchorValue(for: point)) else {
            return nil
        }

        let plotFrame = geometry[plotFrameAnchor]
        let anchor = CGPoint(x: plotFrame.minX + plotX, y: plotFrame.minY + plotY)
        let tooltipSize = CGSize(
            width: showsAllModels ? 230 : 210,
            height: showsAllModels
                ? min(CGFloat(tooltipModelValues(at: point.bucketStart).count) * 25 + 72, 272)
                : singleMetricTooltipHeight
        )
        let spacing: CGFloat = 12
        let showOnLeft = anchor.x > plotFrame.midX
        let desiredX = showOnLeft
            ? anchor.x - spacing - tooltipSize.width / 2
            : anchor.x + spacing + tooltipSize.width / 2
        let desiredY = anchor.y - spacing - tooltipSize.height / 2

        return CGPoint(
            x: min(max(desiredX, tooltipSize.width / 2), geometry.size.width - tooltipSize.width / 2),
            y: min(max(desiredY, tooltipSize.height / 2), geometry.size.height - tooltipSize.height / 2)
        )
    }

    private func hoverDate(for point: DashboardViewModel.BucketPoint) -> Date {
        guard metric == .requests else { return point.bucketStart }
        let end = bucketEnd(after: point.bucketStart)
        return point.bucketStart.addingTimeInterval(end.timeIntervalSince(point.bucketStart) / 2)
    }

    private func tooltipModelValues(at date: Date) -> [DashboardViewModel.ModelTokenPoint] {
        metric == .successRate ? successModelValues(at: date) : modelValues(at: date)
    }

    private var singleMetricTooltipHeight: CGFloat {
        switch metric {
        case .tokens:
            142
        case .successRate:
            137
        case .requests, .decodeSpeed:
            112
        }
    }

    private func tooltipAnchorValue(for point: DashboardViewModel.BucketPoint) -> Double {
        switch metric {
        case .tokens where showsAllModels:
            let values = modelValues(at: point.bucketStart).map(\.totalTokens)
            if allModelsDisplay == .stacked {
                return Double(values.reduce(0, +))
            }
            return Double(values.max() ?? 0)
        case .tokens:
            return Double(max(point.promptTokensTotal, point.generatedTokensTotal))
        case .requests:
            return Double(point.requestsCompleted + point.requestsFailed)
        case .successRate:
            if showsAllModels {
                return successModelValues(at: point.bucketStart).compactMap(\.successRate).max() ?? 0
            }
            return successRate(for: point) ?? 0
        case .decodeSpeed:
            if showsAllModels {
                return modelValues(at: point.bucketStart).compactMap(\.decodeSpeed).max() ?? 0
            }
            return decodeSpeed(for: point) ?? 0
        }
    }
}

private struct SuccessRateHealthChart: View {
    struct Segment: Identifiable {
        let lane: String
        let bucketStart: Date
        let requestsCompleted: Int
        let requestsFailed: Int

        var id: String { "\(lane):\(bucketStart.timeIntervalSince1970)" }

        var totalRequests: Int {
            requestsCompleted + requestsFailed
        }

        var successRate: Double? {
            guard totalRequests > 0 else { return nil }
            return Double(requestsCompleted) / Double(totalRequests)
        }
    }

    let points: [DashboardViewModel.BucketPoint]
    let modelPoints: [DashboardViewModel.ModelTokenPoint]
    let range: DashboardViewModel.RangeOption
    let showsAllModels: Bool
    @State private var hoveredSegmentID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(overallRateLabel)
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                Text(healthStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Chart {
                ForEach(segments) { segment in
                    BarMark(
                        xStart: .value("Bucket start", segment.bucketStart),
                        xEnd: .value("Bucket end", bucketEnd(after: segment.bucketStart)),
                        y: .value("Health lane", segment.lane),
                        height: .ratio(0.72)
                    )
                    .foregroundStyle(color(for: segment).gradient)
                    .opacity(
                        hoveredSegmentID == nil || hoveredSegmentID == segment.id
                            ? segmentOpacity(for: segment)
                            : 0.2
                    )
                    .cornerRadius(3)
                }

                if let hoveredSegment {
                    RuleMark(x: .value("Selected time", midpoint(of: hoveredSegment)))
                        .foregroundStyle(DashboardPalette.axisLabel.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: chartStart...chartEnd)
            .chartYScale(domain: laneDomain)
            .chartXAxis {
                AxisMarks(values: axisDates) { value in
                    AxisGridLine().foregroundStyle(DashboardPalette.axisGrid)
                    AxisTick().foregroundStyle(DashboardPalette.axisTick)
                    if let date = value.as(Date.self) {
                        AxisValueLabel(axisLabel(for: date))
                            .font(.caption2)
                            .foregroundStyle(DashboardPalette.axisText)
                    }
                }
            }
            .chartYAxis {
                if showsAllModels {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Color.clear)
                        AxisTick().foregroundStyle(Color.clear)
                        if let modelID = value.as(String.self) {
                            AxisValueLabel {
                                Text(MLXServerFormatting.truncateModelName(modelID, maxLength: 22))
                                    .font(.caption2)
                                    .foregroundStyle(DashboardPalette.axisText)
                            }
                        }
                    }
                }
            }
            .frame(height: chartHeight)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    updateHoveredSegment(
                                        at: location,
                                        proxy: proxy,
                                        geometry: geometry
                                    )
                                case .ended:
                                    hoveredSegmentID = nil
                                }
                            }

                        if let hoveredSegment,
                           let center = tooltipCenter(
                               for: hoveredSegment,
                               proxy: proxy,
                               geometry: geometry
                           ) {
                            SuccessRateHealthTooltip(
                                segment: hoveredSegment,
                                granularity: granularity,
                                showsModel: showsAllModels
                            )
                            .position(center)
                            .allowsHitTesting(false)
                            .transition(.identity)
                        }
                    }
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var segments: [Segment] {
        if showsAllModels {
            return modelPoints.map {
                Segment(
                    lane: $0.modelID,
                    bucketStart: $0.bucketStart,
                    requestsCompleted: $0.requestsCompleted,
                    requestsFailed: $0.requestsFailed
                )
            }
        }
        return points.map {
            Segment(
                lane: "Reliability",
                bucketStart: $0.bucketStart,
                requestsCompleted: $0.requestsCompleted,
                requestsFailed: $0.requestsFailed
            )
        }
    }

    private var laneDomain: [String] {
        showsAllModels
            ? DashboardModelColorScale.domain(for: modelPoints.map(\.modelID))
            : ["Reliability"]
    }

    private var hoveredSegment: Segment? {
        guard let hoveredSegmentID else { return nil }
        return segments.first { $0.id == hoveredSegmentID }
    }

    private var totalRequests: Int {
        points.reduce(0) { $0 + $1.requestsCompleted + $1.requestsFailed }
    }

    private var completedRequests: Int {
        points.reduce(0) { $0 + $1.requestsCompleted }
    }

    private var failedRequests: Int {
        points.reduce(0) { $0 + $1.requestsFailed }
    }

    private var overallRate: Double? {
        guard totalRequests > 0 else { return nil }
        return Double(completedRequests) / Double(totalRequests)
    }

    private var overallRateLabel: String {
        overallRate.map(MLXServerFormatting.percent) ?? "--"
    }

    private var healthStatus: String {
        guard let overallRate else { return "No requests in this period" }
        if failedRequests == 0 { return "Running smoothly" }
        if overallRate >= 0.95 { return "Mostly healthy" }
        return "Needs attention"
    }

    private var granularity: MLXServerAnalyticsGranularity {
        points.first?.granularity ?? (range == .last24Hours ? .hour : .day)
    }

    private var axisDates: [Date] {
        DashboardChartAxis.markDates(from: points.map(\.bucketStart), maximumCount: 6)
    }

    private var chartStart: Date {
        points.first?.bucketStart ?? Date()
    }

    private var chartEnd: Date {
        guard let last = points.last?.bucketStart else { return Date() }
        return bucketEnd(after: last)
    }

    private var chartHeight: CGFloat {
        max(118, min(CGFloat(laneDomain.count) * 30, 300))
    }

    private func color(for segment: Segment) -> Color {
        guard let successRate = segment.successRate else {
            return Color.secondary.opacity(0.18)
        }
        if segment.requestsFailed == 0 {
            return DashboardPalette.positive
        }
        if successRate >= 0.95 {
            return DashboardPalette.orange
        }
        return DashboardPalette.negative
    }

    private func segmentOpacity(for segment: Segment) -> Double {
        segment.totalRequests == 0 ? 0.45 : 0.92
    }

    private func bucketEnd(after date: Date) -> Date {
        switch granularity {
        case .hour:
            Calendar.current.date(byAdding: .hour, value: 1, to: date) ?? date.addingTimeInterval(3_600)
        case .day:
            Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        }
    }

    private func midpoint(of segment: Segment) -> Date {
        let end = bucketEnd(after: segment.bucketStart)
        return segment.bucketStart.addingTimeInterval(end.timeIntervalSince(segment.bucketStart) / 2)
    }

    private func axisLabel(for date: Date) -> String {
        DashboardChartAxis.label(for: date, granularity: granularity, range: range)
    }

    private func updateHoveredSegment(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrameAnchor = proxy.plotFrame else {
            hoveredSegmentID = nil
            return
        }
        let plotFrame = geometry[plotFrameAnchor]
        guard plotFrame.contains(location) else {
            hoveredSegmentID = nil
            return
        }

        let plotX = location.x - plotFrame.minX
        let plotY = location.y - plotFrame.minY
        guard let date: Date = proxy.value(atX: plotX) else {
            hoveredSegmentID = nil
            return
        }

        let lane: String
        if showsAllModels {
            guard let hoveredLane: String = proxy.value(atY: plotY) else {
                hoveredSegmentID = nil
                return
            }
            lane = hoveredLane
        } else {
            lane = "Reliability"
        }

        hoveredSegmentID = segments.first {
            $0.lane == lane
                && date >= $0.bucketStart
                && date < bucketEnd(after: $0.bucketStart)
        }?.id
    }

    private func tooltipCenter(
        for segment: Segment,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> CGPoint? {
        guard let plotFrameAnchor = proxy.plotFrame,
              let plotX = proxy.position(forX: midpoint(of: segment)),
              let plotY = proxy.position(forY: segment.lane) else {
            return nil
        }

        let plotFrame = geometry[plotFrameAnchor]
        let anchor = CGPoint(x: plotFrame.minX + plotX, y: plotFrame.minY + plotY)
        let tooltipSize = CGSize(width: 220, height: showsAllModels ? 124 : 106)
        let spacing: CGFloat = 12
        let showOnLeft = anchor.x > plotFrame.midX
        let desiredX = showOnLeft
            ? anchor.x - spacing - tooltipSize.width / 2
            : anchor.x + spacing + tooltipSize.width / 2
        let desiredY = anchor.y - spacing - tooltipSize.height / 2

        return CGPoint(
            x: min(max(desiredX, tooltipSize.width / 2), geometry.size.width - tooltipSize.width / 2),
            y: min(max(desiredY, tooltipSize.height / 2), geometry.size.height - tooltipSize.height / 2)
        )
    }
}

private struct SuccessRateHealthTooltip: View {
    let segment: SuccessRateHealthChart.Segment
    let granularity: MLXServerAnalyticsGranularity
    let showsModel: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsModel {
                Text(segment.lane)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(dateLabel)
                .font(.caption.weight(.semibold))

            Divider()

            metricRow("Success", value: successRateLabel, color: DashboardPalette.positive)
            metricRow(
                "Requests",
                value: MLXServerFormatting.integer(segment.totalRequests),
                color: DashboardPalette.indigo
            )
            metricRow(
                "Failed",
                value: MLXServerFormatting.integer(segment.requestsFailed),
                color: DashboardPalette.negative
            )
        }
        .padding(11)
        .frame(width: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DashboardPalette.panelStroke, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var successRateLabel: String {
        segment.successRate.map(MLXServerFormatting.percent) ?? "--"
    }

    private var dateLabel: String {
        if granularity == .hour {
            return segment.bucketStart.formatted(date: .abbreviated, time: .shortened)
        }
        return segment.bucketStart.formatted(date: .long, time: .omitted)
    }

    private func metricRow(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private struct ModelTokenUsageTooltip: View {
    let date: Date
    let points: [DashboardViewModel.ModelTokenPoint]
    let granularity: MLXServerAnalyticsGranularity

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(dateLabel)
                .font(.caption.weight(.semibold))

            ScrollView {
                VStack(spacing: 7) {
                    ForEach(points) { point in
                        HStack(spacing: 10) {
                            Text(point.modelID)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(MLXServerFormatting.integer(point.totalTokens))
                                .fontWeight(.medium)
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxHeight: 190)

            Divider()

            HStack {
                Text("All models")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Text(MLXServerFormatting.integer(totalTokens))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DashboardPalette.panelStroke, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var totalTokens: Int {
        points.reduce(0) { $0 + $1.totalTokens }
    }

    private var dateLabel: String {
        if granularity == .hour {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return date.formatted(date: .long, time: .omitted)
    }
}

private struct ModelOverviewTooltip: View {
    let metric: DashboardOverviewMetric
    let date: Date
    let points: [DashboardViewModel.ModelTokenPoint]
    let granularity: MLXServerAnalyticsGranularity

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(dateLabel)
                .font(.caption.weight(.semibold))

            ScrollView {
                VStack(spacing: 7) {
                    ForEach(points) { point in
                        HStack(spacing: 10) {
                            Text(point.modelID)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(valueLabel(for: point))
                                .fontWeight(.medium)
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxHeight: 190)

            Divider()

            HStack {
                Text("All models")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Text(summaryLabel)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DashboardPalette.panelStroke, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private func valueLabel(for point: DashboardViewModel.ModelTokenPoint) -> String {
        switch metric {
        case .tokens:
            MLXServerFormatting.integer(point.totalTokens)
        case .requests:
            MLXServerFormatting.integer(point.totalRequests)
        case .successRate:
            point.successRate.map(MLXServerFormatting.percent) ?? "--"
        case .decodeSpeed:
            MLXServerFormatting.rate(point.decodeSpeed)
        }
    }

    private var summaryLabel: String {
        switch metric {
        case .tokens:
            return MLXServerFormatting.integer(points.reduce(0) { $0 + $1.totalTokens })
        case .requests:
            return MLXServerFormatting.integer(points.reduce(0) { $0 + $1.totalRequests })
        case .successRate:
            guard totalRequests > 0 else { return "--" }
            let completed = points.reduce(0) { $0 + $1.requestsCompleted }
            return MLXServerFormatting.percent(Double(completed) / Double(totalRequests))
        case .decodeSpeed:
            let generatedTokens = points.reduce(0) { $0 + $1.generatedTokensTotal }
            let decodeMilliseconds = points.reduce(Int64.zero) { $0 + $1.decodeTimeTotalMilliseconds }
            guard generatedTokens > 0, decodeMilliseconds > 0 else { return "--" }
            let speed = Double(generatedTokens) / (Double(decodeMilliseconds) / 1_000)
            return MLXServerFormatting.rate(speed)
        }
    }

    private var totalRequests: Int {
        points.reduce(0) { $0 + $1.totalRequests }
    }

    private var dateLabel: String {
        if granularity == .hour {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return date.formatted(date: .long, time: .omitted)
    }
}

private struct TokenUsageTooltip: View {
    let point: DashboardViewModel.BucketPoint
    let granularity: MLXServerAnalyticsGranularity

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(dateLabel)
                .font(.caption.weight(.semibold))

            TokenUsageTooltipRow(
                title: "Input",
                value: point.promptTokensTotal,
                color: DashboardPalette.accent
            )
            TokenUsageTooltipRow(
                title: "Output",
                value: point.generatedTokensTotal,
                color: DashboardPalette.indigo
            )

            Divider()

            HStack {
                Text("Total")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 22)
                Text(MLXServerFormatting.integer(point.processedTokensTotal))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 174)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DashboardPalette.panelStroke, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var dateLabel: String {
        if granularity == .hour {
            return point.bucketStart.formatted(date: .abbreviated, time: .shortened)
        }
        return point.bucketStart.formatted(date: .long, time: .omitted)
    }
}

private struct TokenUsageTooltipRow: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).foregroundStyle(.secondary)
            }
            Spacer(minLength: 22)
            Text(MLXServerFormatting.integer(value))
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private struct DashboardMetricTooltip: View {
    let metric: DashboardOverviewMetric
    let point: DashboardViewModel.BucketPoint
    let granularity: MLXServerAnalyticsGranularity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dateLabel)
                .font(.caption.weight(.semibold))

            switch metric {
            case .tokens:
                EmptyView()
            case .requests:
                metricRow(
                    "Completed",
                    value: MLXServerFormatting.integer(point.requestsCompleted),
                    color: DashboardPalette.positive
                )
                metricRow(
                    "Failed",
                    value: MLXServerFormatting.integer(point.requestsFailed),
                    color: DashboardPalette.negative
                )
            case .successRate:
                metricRow(
                    "Success rate",
                    value: successRate.map(MLXServerFormatting.percent) ?? "--",
                    color: DashboardPalette.positive
                )
                metricRow(
                    "Requests",
                    value: MLXServerFormatting.integer(totalRequests),
                    color: DashboardPalette.indigo
                )
                metricRow(
                    "Failed",
                    value: MLXServerFormatting.integer(point.requestsFailed),
                    color: DashboardPalette.negative
                )
            case .decodeSpeed:
                metricRow(
                    "Decode speed",
                    value: MLXServerFormatting.rate(decodeSpeed),
                    color: DashboardPalette.orange
                )
                metricRow(
                    "Generated",
                    value: "\(MLXServerFormatting.integer(point.generatedTokensTotal)) tokens",
                    color: DashboardPalette.indigo
                )
            }
        }
        .padding(11)
        .frame(width: 210)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DashboardPalette.panelStroke, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var totalRequests: Int {
        point.requestsCompleted + point.requestsFailed
    }

    private var successRate: Double? {
        guard totalRequests > 0 else { return nil }
        return Double(point.requestsCompleted) / Double(totalRequests)
    }

    private var decodeSpeed: Double? {
        guard point.generatedTokensTotal > 0, point.decodeTimeTotalMilliseconds > 0 else {
            return nil
        }
        return Double(point.generatedTokensTotal) / (Double(point.decodeTimeTotalMilliseconds) / 1_000)
    }

    private var dateLabel: String {
        if granularity == .hour {
            return point.bucketStart.formatted(date: .abbreviated, time: .shortened)
        }
        return point.bucketStart.formatted(date: .long, time: .omitted)
    }

    private func metricRow(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private struct ChartLegendDot: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct RequestHealthPanel: View {
    let points: [DashboardViewModel.BucketPoint]
    let completed: Int
    let failed: Int
    let range: DashboardViewModel.RangeOption
    let minimumHeight: CGFloat
    @State private var hoveredPointID: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AnalyticsSectionHeader(
                title: "Request health",
                subtitle: "Completion volume and reliability"
            )

            HStack(alignment: .firstTextBaseline) {
                Text(total == 0 ? "--" : MLXServerFormatting.percent(Double(completed) / Double(total)))
                    .font(.system(size: 29, weight: .semibold, design: .rounded).monospacedDigit())
                Text("successful")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if points.isEmpty {
                DashboardEmptyChart()
                    .frame(minHeight: 120, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(points) { point in
                        BarMark(
                            x: .value("Time", point.bucketStart),
                            y: .value("Completed", point.requestsCompleted)
                        )
                        .foregroundStyle(DashboardPalette.positive.gradient)
                        .cornerRadius(2)
                    }

                    if let hoveredPoint {
                        RuleMark(x: .value("Selected time", hoveredPoint.bucketStart))
                            .foregroundStyle(DashboardPalette.axisLabel.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                        PointMark(
                            x: .value("Selected time", hoveredPoint.bucketStart),
                            y: .value("Completed", hoveredPoint.requestsCompleted)
                        )
                        .foregroundStyle(DashboardPalette.positive)
                        .symbolSize(42)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: axisDates) { value in
                        AxisGridLine().foregroundStyle(Color.clear)
                        AxisTick().foregroundStyle(DashboardPalette.axisTick)
                        if let date = value.as(Date.self) {
                            AxisValueLabel(axisLabel(for: date))
                                .font(.caption2)
                                .foregroundStyle(DashboardPalette.axisText)
                        }
                    }
                }
                .chartYAxis(.hidden)
                .frame(minHeight: 118, maxHeight: .infinity)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        updateHoveredPoint(
                                            at: location,
                                            proxy: proxy,
                                            geometry: geometry
                                        )
                                    case .ended:
                                        hoveredPointID = nil
                                    }
                                }

                            if let hoveredPoint,
                               let tooltipCenter = tooltipCenter(
                                   for: hoveredPoint,
                                   proxy: proxy,
                                   geometry: geometry
                               ) {
                                RequestHealthTooltip(
                                    point: hoveredPoint,
                                    granularity: granularity
                                )
                                .position(tooltipCenter)
                                .allowsHitTesting(false)
                                .transition(.identity)
                            }
                        }
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                    }
                }
                .onChange(of: points) { _, newPoints in
                    if let hoveredPointID,
                       !newPoints.contains(where: { $0.id == hoveredPointID }) {
                        self.hoveredPointID = nil
                    }
                }
            }

            Divider()

            HStack {
                RequestHealthStat(title: "Completed", value: completed, color: DashboardPalette.positive)
                Spacer()
                RequestHealthStat(title: "Failed", value: failed, color: DashboardPalette.negative)
            }
        }
        .padding(18)
        .frame(minHeight: minimumHeight, alignment: .top)
        .dashboardPanelStyle(cornerRadius: 14)
    }

    private var total: Int { completed + failed }

    private var hoveredPoint: DashboardViewModel.BucketPoint? {
        guard let hoveredPointID else { return nil }
        return points.first { $0.id == hoveredPointID }
    }

    private var granularity: MLXServerAnalyticsGranularity {
        points.first?.granularity ?? .hour
    }

    private var axisDates: [Date] {
        DashboardChartAxis.markDates(from: points.map(\.bucketStart), maximumCount: 4)
    }

    private func axisLabel(for date: Date) -> String {
        DashboardChartAxis.label(
            for: date,
            granularity: granularity,
            range: range
        )
    }

    private func updateHoveredPoint(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrameAnchor = proxy.plotFrame else {
            hoveredPointID = nil
            return
        }

        let plotFrame = geometry[plotFrameAnchor]
        guard plotFrame.contains(location) else {
            hoveredPointID = nil
            return
        }

        let plotX = location.x - plotFrame.minX
        guard let hoveredDate: Date = proxy.value(atX: plotX) else {
            hoveredPointID = nil
            return
        }

        let nextPoint = points.min {
            abs($0.bucketStart.timeIntervalSince(hoveredDate))
                < abs($1.bucketStart.timeIntervalSince(hoveredDate))
        }
        guard hoveredPointID != nextPoint?.id else { return }
        hoveredPointID = nextPoint?.id
    }

    private func tooltipCenter(
        for point: DashboardViewModel.BucketPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> CGPoint? {
        guard let plotFrameAnchor = proxy.plotFrame,
              let plotX = proxy.position(forX: point.bucketStart),
              let plotY = proxy.position(forY: point.requestsCompleted) else {
            return nil
        }

        let plotFrame = geometry[plotFrameAnchor]
        let anchor = CGPoint(x: plotFrame.minX + plotX, y: plotFrame.minY + plotY)
        let tooltipSize = CGSize(width: 210, height: 102)
        let spacing: CGFloat = 10
        let showOnLeft = anchor.x > plotFrame.midX
        let desiredX = showOnLeft
            ? anchor.x - spacing - tooltipSize.width / 2
            : anchor.x + spacing + tooltipSize.width / 2
        let desiredY = anchor.y - spacing - tooltipSize.height / 2

        return CGPoint(
            x: min(max(desiredX, tooltipSize.width / 2), geometry.size.width - tooltipSize.width / 2),
            y: min(max(desiredY, tooltipSize.height / 2), geometry.size.height - tooltipSize.height / 2)
        )
    }
}

private struct RequestHealthTooltip: View {
    let point: DashboardViewModel.BucketPoint
    let granularity: MLXServerAnalyticsGranularity

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(dateLabel)
                .font(.caption.weight(.semibold))

            HStack(spacing: 12) {
                metric("Completed", value: point.requestsCompleted, color: DashboardPalette.positive)
                metric("Failed", value: point.requestsFailed, color: DashboardPalette.negative)
            }

            Divider()

            HStack {
                Text("Total \(MLXServerFormatting.integer(total))")
                Spacer(minLength: 8)
                Text(successRate)
                    .fontWeight(.semibold)
            }
            .font(.caption)
            .monospacedDigit()
        }
        .padding(10)
        .frame(width: 210)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DashboardPalette.panelStroke, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var total: Int {
        point.requestsCompleted + point.requestsFailed
    }

    private var successRate: String {
        guard total > 0 else { return "--" }
        return MLXServerFormatting.percent(Double(point.requestsCompleted) / Double(total))
    }

    private var dateLabel: String {
        if granularity == .hour {
            return point.bucketStart.formatted(date: .abbreviated, time: .shortened)
        }
        return point.bucketStart.formatted(date: .long, time: .omitted)
    }

    private func metric(_ title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .foregroundStyle(.secondary)
            Text(MLXServerFormatting.integer(value))
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private struct TokenUsagePanelHeightReader: View {
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: TokenUsagePanelHeightPreferenceKey.self,
                value: geometry.size.height
            )
        }
    }
}

private struct TokenUsagePanelHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct RequestHealthStat: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            Text(MLXServerFormatting.compactCount(value).display)
                .font(.callout.weight(.semibold).monospacedDigit())
        }
    }
}

private struct ModelPerformanceTable: View {
    enum SortColumn: String {
        case model
        case tokens
        case requests
        case success
        case decode
        case peakMemory
    }

    let rows: [DashboardViewModel.ModelPerformance]
    let modelColorDomain: [String]
    let searchFocus: FocusState<Bool>.Binding

    @State private var searchText = ""
    @State private var sortColumn: SortColumn = .tokens
    @State private var sortAscending = false
    @State private var showsAllModels = false

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No model activity",
                    systemImage: "cpu",
                    description: Text("Model performance will appear after requests are processed.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ViewThatFits(in: .horizontal) {
                    tableContent
                        .frame(minWidth: minimumTableWidth, maxWidth: .infinity)

                    ScrollView(.horizontal) {
                        tableContent
                            .frame(width: minimumTableWidth)
                    }
                    .scrollIndicators(.visible)
                }
            }
        }
        .padding(.horizontal, 16)
        .dashboardPanelStyle(cornerRadius: 14)
    }

    private var tableContent: some View {
        VStack(spacing: 0) {
            tableToolbar
            Divider().overlay(DashboardPalette.panelStroke)
            modelRowHeader

            if visibleRows.isEmpty {
                Divider().overlay(DashboardPalette.panelStroke)
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visibleRows) { row in
                        Divider().overlay(DashboardPalette.panelStroke)
                        modelRow(row)
                    }
                }
            }
        }
    }

    private var tableToolbar: some View {
        HStack(spacing: 12) {
            TextField("Search models", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .focused(searchFocus)
                .onSubmit {
                    searchFocus.wrappedValue = false
                }
                .frame(width: 260)

            Spacer(minLength: 16)

            Text("Showing \(visibleRows.count) of \(sortedRows.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if searchText.isEmpty, sortedRows.count > defaultVisibleLimit {
                Button(showsAllModels ? "Show top \(defaultVisibleLimit)" : "Show all") {
                    searchFocus.wrappedValue = false
                    showsAllModels.toggle()
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 12)
    }

    private var modelRowHeader: some View {
        HStack(spacing: 18) {
            sortableHeader("Model", column: .model, width: nil, alignment: .leading)
            sortableHeader("Tokens", column: .tokens, width: 105, alignment: .trailing)
            sortableHeader("Requests", column: .requests, width: 90, alignment: .trailing)
            sortableHeader("Success", column: .success, width: 85, alignment: .trailing)
            sortableHeader("Decode", column: .decode, width: 105, alignment: .trailing)
            sortableHeader("Peak memory", column: .peakMemory, width: 105, alignment: .trailing)
        }
        .padding(.vertical, 12)
    }

    private func modelRow(_ row: DashboardViewModel.ModelPerformance) -> some View {
        HStack(spacing: 18) {
            HStack(spacing: 10) {
                ModelPerformanceProviderBadge(modelID: row.modelID)

                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(modelColor(for: row.modelID))
                    .frame(width: 3, height: 24)

                Text(row.modelID)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                    .help(row.modelID)
            }
            .frame(minWidth: modelColumnMinimumWidth, maxWidth: .infinity, alignment: .leading)

            tableValue(MLXServerFormatting.compactCount(row.processedTokens).display, width: 105)
            tableValue(MLXServerFormatting.integer(row.totalRequests), width: 90)
            tableValue(row.successRate.map(MLXServerFormatting.percent) ?? "--", width: 85)
            tableValue(MLXServerFormatting.rate(row.averageDecodeTokensPerSecond), width: 105)
            tableValue(MLXServerFormatting.gigabytes(fromBytes: row.peakMemoryBytes), width: 105)
        }
        .padding(.vertical, 13)
    }

    private func sortableHeader(
        _ title: String,
        column: SortColumn,
        width: CGFloat?,
        alignment: Alignment
    ) -> some View {
        Group {
            if let width {
                sortButton(title, column: column)
                    .frame(width: width, alignment: alignment)
            } else {
                sortButton(title, column: column).frame(
                    minWidth: modelColumnMinimumWidth,
                    maxWidth: .infinity,
                    alignment: alignment
                )
            }
        }
    }

    private func sortButton(_ title: String, column: SortColumn) -> some View {
        Button {
            searchFocus.wrappedValue = false
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = column == .model
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Sort by \(title.lowercased())")
    }

    private func tableValue(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .trailing)
    }

    private var filteredRows: [DashboardViewModel.ModelPerformance] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.modelID.localizedCaseInsensitiveContains(query) }
    }

    private var sortedRows: [DashboardViewModel.ModelPerformance] {
        filteredRows.sorted(by: comesBefore)
    }

    private var visibleRows: [DashboardViewModel.ModelPerformance] {
        if showsAllModels || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sortedRows
        }
        return Array(sortedRows.prefix(defaultVisibleLimit))
    }

    private func comesBefore(
        _ lhs: DashboardViewModel.ModelPerformance,
        _ rhs: DashboardViewModel.ModelPerformance
    ) -> Bool {
        if sortColumn == .model {
            let comparison = lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID)
            if comparison == .orderedSame { return lhs.modelID < rhs.modelID }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }

        let lhsValue = numericSortValue(for: lhs)
        let rhsValue = numericSortValue(for: rhs)
        switch (lhsValue, rhsValue) {
        case (.none, .none):
            return lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
        case (.none, .some):
            return false
        case (.some, .none):
            return true
        case (.some(let lhsValue), .some(let rhsValue)):
            if lhsValue == rhsValue {
                return lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
            }
            return sortAscending ? lhsValue < rhsValue : lhsValue > rhsValue
        }
    }

    private func numericSortValue(for row: DashboardViewModel.ModelPerformance) -> Double? {
        switch sortColumn {
        case .model:
            nil
        case .tokens:
            Double(row.processedTokens)
        case .requests:
            Double(row.totalRequests)
        case .success:
            row.successRate
        case .decode:
            row.averageDecodeTokensPerSecond
        case .peakMemory:
            row.peakMemoryBytes.map(Double.init)
        }
    }

    private func modelColor(for modelID: String) -> Color {
        if modelColorDomain.contains(modelID) {
            return DashboardModelColorScale.color(for: modelID, in: modelColorDomain)
        }
        return DashboardModelColorScale.color(for: "Other", in: modelColorDomain)
    }

    private var defaultVisibleLimit: Int { 12 }
    private var modelColumnMinimumWidth: CGFloat { 280 }
    private var minimumTableWidth: CGFloat { 900 }
}

private struct SessionCardValue: Identifiable {
    let title: String
    let value: String
    let help: String?

    var id: String { title }
}

private struct SessionMetricCard: View {
    let card: SessionCardValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(card.value)
                .font(.title3.monospacedDigit())
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .dashboardPanelStyle()
        .help(card.help ?? card.value)
    }
}

private struct DashboardPickerContainer<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .dashboardPanelStyle(cornerRadius: 10)
    }
}

private struct DashboardPeriodSelector: View {
    @Binding var selection: DashboardViewModel.RangeOption

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DashboardViewModel.RangeOption.allCases) { option in
                Button {
                    selection = option
                } label: {
                    Text(option.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .foregroundStyle(selection == option ? Color.white : Color.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selection == option ? Color.accentColor : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DashboardPalette.panelStroke, lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.12), value: selection)
        .accessibilityLabel("Period")
    }
}

private struct SummaryPill: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .dashboardPanelStyle(cornerRadius: 10)
        .help(value)
    }
}

private struct HistoricalChartCard<Content: View>: View {
    let title: String
    let help: String
    let content: Content

    init(title: String, help: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                DashboardInfoButton(text: help)
            }

            content
        }
        .padding(16)
        .dashboardPanelStyle(cornerRadius: 14)
    }
}

private struct DashboardInfoButton: View {
    let text: String

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DashboardInfoPopover(text: text)
        }
        .accessibilityLabel("More information")
        .accessibilityHint(text)
    }
}

private struct DashboardInfoPopover: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.primary)
            .frame(width: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
    }
}

private struct ModelPerformanceProviderBadge: View {
    let modelID: String
    @Environment(\.colorScheme) private var colorScheme

    private var provider: LocalModelProvider? {
        LocalModelProviderResolver.resolve(
            repoID: modelID,
            modelType: nil,
            architectures: []
        )
    }

    private var backgroundColor: Color {
        if provider?.needsLightIconBackgroundInDarkMode == true, colorScheme == .dark {
            return Color.white.opacity(0.92)
        }
        return Color.secondary.opacity(0.10)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundColor)

            if let provider, let image = LocalModelProviderIcon.image(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .accessibilityLabel(provider.displayName)
            } else if let provider {
                Text(provider.monogram)
                    .font(.system(size: provider.monogram.count > 2 ? 7 : 10, weight: .bold))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .help(provider?.displayName ?? "Unknown provider")
    }
}

private struct DashboardRecentRequestsTable: View {
    let requests: [MLXServerAnalyticsRequestEvent]
    @State private var selectedRequest: MLXServerAnalyticsRequestEvent?

    var body: some View {
        Group {
            if requests.isEmpty {
                ContentUnavailableView(
                    "No recent requests",
                    systemImage: "list.bullet.rectangle",
                    description: Text("No requests match the current dashboard filters.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 0) {
                        DashboardRecentRequestsHeaderRow()

                        ForEach(Array(requests.enumerated()), id: \.element.id) { index, request in
                            Divider()
                                .overlay(DashboardPalette.panelStroke)

                            Button {
                                selectedRequest = request
                            } label: {
                                DashboardRecentRequestsDataRow(request: request)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.01))
                        }
                    }
                    .frame(
                        minWidth: DashboardRecentRequestsColumn.minimumTableWidth,
                        alignment: .leading
                    )
                }
            }
        }
        .padding(16)
        .dashboardPanelStyle(cornerRadius: 14)
        .sheet(item: $selectedRequest) { request in
            RequestDetailView(request: request)
        }
    }
}

private struct RequestDetailView: View {
    let request: MLXServerAnalyticsRequestEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Request details")
                        .font(.title2.weight(.semibold))
                    Text(request.completedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(request.modelID)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(request.requestID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: 12
            ) {
                RequestDetailMetric(title: "Prompt tokens", value: MLXServerFormatting.integer(request.promptTokens))
                RequestDetailMetric(title: "Output tokens", value: MLXServerFormatting.integer(request.generatedTokens))
                RequestDetailMetric(title: "Elapsed", value: "\(MLXServerFormatting.seconds(fromMilliseconds: request.requestElapsedMilliseconds))s")
                RequestDetailMetric(title: "Prefill", value: "\(MLXServerFormatting.decimal(request.resolvedPrefillTokensPerSecond)) tok/s")
                RequestDetailMetric(title: "Decode", value: "\(MLXServerFormatting.decimal(request.resolvedDecodeTokensPerSecond)) tok/s")
                RequestDetailMetric(title: "Peak memory", value: MLXServerFormatting.gigabytes(fromBytes: request.peakMemoryBytes))
            }

            HStack(spacing: 10) {
                DashboardRequestBadge(
                    text: request.status == "completed" ? "Completed" : "Failed",
                    style: request.status == "completed" ? .finish : .failure
                )
                DashboardRequestBadge(
                    text: request.streaming ? "Streaming" : "Standard",
                    style: .text
                )
                Text(request.endpoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

private struct RequestDetailMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .dashboardPanelStyle(cornerRadius: 10)
    }
}

private struct DashboardRecentRequestsHeaderRow: View {
    var body: some View {
        HStack(spacing: DashboardRecentRequestsColumn.horizontalSpacing) {
            ForEach(DashboardRecentRequestsColumn.allCases, id: \.self) { column in
                Text(column.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: column.width, alignment: column.alignment)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

private struct DashboardRecentRequestsDataRow: View {
    let request: MLXServerAnalyticsRequestEvent

    var body: some View {
        HStack(spacing: DashboardRecentRequestsColumn.horizontalSpacing) {
            ForEach(DashboardRecentRequestsColumn.allCases, id: \.self) { column in
                cell(for: column)
                    .frame(width: column.width, alignment: column.alignment)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .font(.body.monospacedDigit())
    }

    @ViewBuilder
    private func cell(for column: DashboardRecentRequestsColumn) -> some View {
        switch column {
        case .time:
            Text(request.completedAt.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(.secondary)
        case .model:
            Text(request.modelID)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(request.modelID)
        case .finish:
            DashboardRequestBadge(
                text: finishTitle,
                style: finishStyle
            )
            .help(finishTitle)
        case .mode:
            DashboardRequestBadge(
                text: modeTitle,
                style: modeStyle
            )
            .help(modeTitle)
        case .prompt:
            Text(MLXServerFormatting.integer(request.promptTokens))
        case .completion:
            Text(MLXServerFormatting.integer(request.completionTokens))
        case .prefill:
            Text(MLXServerFormatting.decimal(request.resolvedPrefillTokensPerSecond))
        case .decode:
            Text(MLXServerFormatting.decimal(request.resolvedDecodeTokensPerSecond))
        case .request:
            Text(MLXServerFormatting.decimal(request.requestTokensPerSecond))
        case .elapsed:
            Text(MLXServerFormatting.seconds(fromMilliseconds: request.requestElapsedMilliseconds))
        case .peakMemory:
            Text(MLXServerFormatting.gigabytes(fromBytes: request.peakMemoryBytes))
        }
    }

    private var finishTitle: String {
        if request.status != "completed" {
            return "Failed"
        }

        if let finishReason = request.finishReason,
           !finishReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MLXServerFormatting.titleizedIdentifier(finishReason)
        }

        return "Completed"
    }

    private var finishStyle: DashboardRequestBadgeStyle {
        request.status == "completed" ? .finish : .failure
    }

    private var modeTitle: String {
        if request.toolCalls {
            return "Tools"
        }
        if request.structuredOutput {
            return "JSON"
        }
        return "Text"
    }

    private var modeStyle: DashboardRequestBadgeStyle {
        if request.toolCalls {
            return .tools
        }
        if request.structuredOutput {
            return .json
        }
        return .text
    }
}

private struct DashboardRequestBadge: View {
    let text: String
    let style: DashboardRequestBadgeStyle

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(style.foregroundColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(style.backgroundColor)
            )
            .lineLimit(1)
    }
}

private struct DashboardRequestBadgeStyle {
    let foregroundColor: Color
    let backgroundColor: Color

    static let finish = DashboardRequestBadgeStyle(
        foregroundColor: DashboardPalette.finishBadgeForeground,
        backgroundColor: DashboardPalette.finishBadgeBackground
    )
    static let failure = DashboardRequestBadgeStyle(
        foregroundColor: DashboardPalette.failureBadgeForeground,
        backgroundColor: DashboardPalette.failureBadgeBackground
    )
    static let json = DashboardRequestBadgeStyle(
        foregroundColor: DashboardPalette.jsonBadgeForeground,
        backgroundColor: DashboardPalette.jsonBadgeBackground
    )
    static let tools = DashboardRequestBadgeStyle(
        foregroundColor: DashboardPalette.toolsBadgeForeground,
        backgroundColor: DashboardPalette.toolsBadgeBackground
    )
    static let text = DashboardRequestBadgeStyle(
        foregroundColor: DashboardPalette.textBadgeForeground,
        backgroundColor: DashboardPalette.textBadgeBackground
    )
}

private enum DashboardRecentRequestsColumn: CaseIterable {
    case time
    case model
    case finish
    case mode
    case prompt
    case completion
    case prefill
    case decode
    case request
    case elapsed
    case peakMemory

    static let horizontalSpacing: CGFloat = 24

    var title: String {
        switch self {
        case .time:
            "Time"
        case .model:
            "Model"
        case .finish:
            "Finish"
        case .mode:
            "Mode"
        case .prompt:
            "Prompt"
        case .completion:
            "Completion"
        case .prefill:
            "Prefill tok/s"
        case .decode:
            "Decode tok/s"
        case .request:
            "Request tok/s"
        case .elapsed:
            "Elapsed"
        case .peakMemory:
            "Peak memory"
        }
    }

    var width: CGFloat {
        switch self {
        case .time:
            130
        case .model:
            210
        case .finish:
            100
        case .mode:
            92
        case .prompt:
            86
        case .completion:
            104
        case .prefill, .decode, .request:
            132
        case .elapsed:
            92
        case .peakMemory:
            112
        }
    }

    var alignment: Alignment {
        switch self {
        case .time, .model:
            .leading
        case .finish, .mode:
            .center
        case .prompt, .completion, .prefill, .decode, .request, .elapsed, .peakMemory:
            .trailing
        }
    }

    static var minimumTableWidth: CGFloat {
        let contentWidth = allCases.reduce(CGFloat.zero) { partialResult, column in
            partialResult + column.width
        }
        let spacingWidth = CGFloat(max(allCases.count - 1, 0)) * horizontalSpacing
        return contentWidth + spacingWidth + 24
    }
}

private enum DashboardChartMetric {
    case processed
    case generated
    case prompt

    func value(for point: DashboardViewModel.BucketPoint) -> Double {
        switch self {
        case .processed:
            Double(point.processedTokensTotal)
        case .generated:
            Double(point.generatedTokensTotal)
        case .prompt:
            Double(point.promptTokensTotal)
        }
    }
}

private struct DashboardTokenChart: View {
    let points: [DashboardViewModel.BucketPoint]
    let range: DashboardViewModel.RangeOption
    let metric: DashboardChartMetric

    var body: some View {
        if points.isEmpty {
            DashboardEmptyChart()
        } else {
            Chart {
                ForEach(points) { point in
                    BarMark(
                        x: .value("Bucket", point.bucketStart),
                        y: .value("Value", metric.value(for: point))
                    )
                    .foregroundStyle(DashboardPalette.primaryBar)
                }
            }
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: xAxisDates) { value in
                    AxisGridLine().foregroundStyle(Color.clear)
                    AxisTick().foregroundStyle(Color.clear)
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(axisLabel(for: date))
                                .font(.caption2)
                                .foregroundStyle(DashboardPalette.axisLabel)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.clear)
                    AxisTick().foregroundStyle(Color.clear)
                    if let rawValue = value.as(Double.self) {
                        AxisValueLabel(centered: false) {
                            Text(yAxisLabel(for: rawValue))
                                .font(.caption2)
                                .foregroundStyle(DashboardPalette.axisLabel)
                        }
                    }
                }
            }
            .frame(height: 180)
        }
    }

    private func yAxisLabel(for value: Double) -> String {
        MLXServerFormatting.compactCount(Int(value.rounded())).display
    }

    private var chartGranularity: MLXServerAnalyticsGranularity {
        points.first?.granularity ?? fallbackGranularity
    }

    private var fallbackGranularity: MLXServerAnalyticsGranularity {
        switch range {
        case .last24Hours:
            .hour
        case .last7Days, .last30Days, .lastYear, .allTime:
            .day
        }
    }

    private var xAxisDates: [Date] {
        DashboardChartAxis.markDates(
            from: points.map(\.bucketStart),
            maximumCount: chartGranularity == .hour ? 6 : 5
        )
    }

    private func axisLabel(for date: Date) -> String {
        switch chartGranularity {
        case .hour:
            DashboardFormatters.hourLabel.string(from: date).lowercased()
        case .day:
            DashboardFormatters.dayLabel.string(from: date)
        }
    }
}

private struct DashboardRequestChart: View {
    let points: [DashboardViewModel.BucketPoint]
    let range: DashboardViewModel.RangeOption

    var body: some View {
        if points.isEmpty {
            DashboardEmptyChart()
        } else {
            Chart {
                ForEach(requestSegments) { segment in
                    BarMark(
                        x: .value("Bucket", segment.bucketStart),
                        y: .value("Requests", segment.count)
                    )
                    .foregroundStyle(segment.color)
                }
            }
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: xAxisDates) { value in
                    AxisGridLine().foregroundStyle(Color.clear)
                    AxisTick().foregroundStyle(Color.clear)
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(axisLabel(for: date))
                                .font(.caption2)
                                .foregroundStyle(DashboardPalette.axisLabel)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.clear)
                    AxisTick().foregroundStyle(Color.clear)
                    if let rawValue = value.as(Double.self) {
                        AxisValueLabel(centered: false) {
                            Text(MLXServerFormatting.compactCount(Int(rawValue.rounded())).display)
                                .font(.caption2)
                                .foregroundStyle(DashboardPalette.axisLabel)
                        }
                    }
                }
            }
            .frame(height: 180)
        }
    }

    private var chartGranularity: MLXServerAnalyticsGranularity {
        points.first?.granularity ?? fallbackGranularity
    }

    private var fallbackGranularity: MLXServerAnalyticsGranularity {
        switch range {
        case .last24Hours:
            .hour
        case .last7Days, .last30Days, .lastYear, .allTime:
            .day
        }
    }

    private var xAxisDates: [Date] {
        DashboardChartAxis.markDates(
            from: points.map(\.bucketStart),
            maximumCount: chartGranularity == .hour ? 6 : 5
        )
    }

    private var requestSegments: [RequestSegment] {
        points.flatMap { point in
            var segments: [RequestSegment] = []
            if point.requestsFailed > 0 {
                segments.append(
                    RequestSegment(
                        bucketStart: point.bucketStart,
                        kind: "failed",
                        count: point.requestsFailed,
                        color: DashboardPalette.failureBar
                    )
                )
            }
            if point.requestsCompleted > 0 {
                segments.append(
                    RequestSegment(
                        bucketStart: point.bucketStart,
                        kind: "completed",
                        count: point.requestsCompleted,
                        color: DashboardPalette.successBar
                    )
                )
            }
            return segments
        }
    }

    private func axisLabel(for date: Date) -> String {
        switch chartGranularity {
        case .hour:
            DashboardFormatters.hourLabel.string(from: date).lowercased()
        case .day:
            DashboardFormatters.dayLabel.string(from: date)
        }
    }
}

private enum DashboardChartAxis {
    static func markDates(from dates: [Date], maximumCount: Int) -> [Date] {
        guard dates.count > maximumCount, maximumCount > 1 else {
            return dates
        }

        let step = Double(dates.count - 1) / Double(maximumCount - 1)
        var indexes = Set([0, dates.count - 1])

        for markIndex in 1..<(maximumCount - 1) {
            indexes.insert(Int(round(Double(markIndex) * step)))
        }

        return indexes
            .sorted()
            .map { dates[$0] }
    }

    static func label(
        for date: Date,
        granularity: MLXServerAnalyticsGranularity,
        range: DashboardViewModel.RangeOption
    ) -> String {
        switch granularity {
        case .hour where range == .allTime:
            let day = DashboardFormatters.dayLabel.string(from: date)
            let hour = DashboardFormatters.hourLabel.string(from: date).lowercased()
            return "\(day)\n\(hour)"
        case .hour:
            return DashboardFormatters.hourLabel.string(from: date).lowercased()
        case .day:
            return DashboardFormatters.dayLabel.string(from: date)
        }
    }
}

private struct RequestSegment: Identifiable {
    let bucketStart: Date
    let kind: String
    let count: Int
    let color: Color

    var id: String {
        "\(bucketStart.timeIntervalSince1970)-\(kind)-\(count)"
    }
}

private struct DashboardEmptyChart: View {
    var body: some View {
        ContentUnavailableView(
            "No analytics yet",
            systemImage: "chart.bar.xaxis",
            description: Text("No data is available for the selected filters.")
        )
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

private enum DashboardPalette {
    static let accent = Color(red: 71 / 255, green: 151 / 255, blue: 232 / 255)
    static let indigo = Color(red: 119 / 255, green: 105 / 255, blue: 234 / 255)
    static let positive = Color(red: 62 / 255, green: 179 / 255, blue: 131 / 255)
    static let negative = Color(red: 225 / 255, green: 91 / 255, blue: 101 / 255)
    static let orange = Color(red: 232 / 255, green: 151 / 255, blue: 65 / 255)
    static let primaryBar = Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
    static let successBar = Color(red: 68 / 255, green: 157 / 255, blue: 187 / 255)
    static let failureBar = Color(red: 181 / 255, green: 51 / 255, blue: 63 / 255)
    static let panelFill = Color(nsColor: .controlBackgroundColor)
    static let panelStroke = Color(nsColor: .separatorColor).opacity(0.6)
    static let axisLabel = Color(nsColor: .tertiaryLabelColor)
    static let axisText = Color(nsColor: .secondaryLabelColor)
    static let axisTick = Color(nsColor: .secondaryLabelColor).opacity(0.78)
    static let axisGrid = Color(nsColor: .separatorColor).opacity(0.72)
    static let finishBadgeForeground = Color(red: 150 / 255, green: 188 / 255, blue: 245 / 255)
    static let finishBadgeBackground = Color(red: 34 / 255, green: 58 / 255, blue: 100 / 255)
    static let failureBadgeForeground = Color(red: 245 / 255, green: 183 / 255, blue: 188 / 255)
    static let failureBadgeBackground = Color(red: 95 / 255, green: 28 / 255, blue: 36 / 255)
    static let jsonBadgeForeground = Color(red: 205 / 255, green: 245 / 255, blue: 140 / 255)
    static let jsonBadgeBackground = Color(red: 82 / 255, green: 122 / 255, blue: 36 / 255)
    static let toolsBadgeForeground = Color(red: 255 / 255, green: 220 / 255, blue: 145 / 255)
    static let toolsBadgeBackground = Color(red: 112 / 255, green: 76 / 255, blue: 18 / 255)
    static let textBadgeForeground = Color(nsColor: .secondaryLabelColor)
    static let textBadgeBackground = Color(nsColor: .quaternaryLabelColor).opacity(0.28)
}

private enum DashboardModelColorScale {
    static let palette: [Color] = [
        .blue,
        .green,
        .orange,
        .purple,
        .pink,
        .cyan,
        .yellow,
        .mint,
        .indigo,
        .red,
        .teal,
        .brown,
    ]

    static func domain(for modelIDs: [String]) -> [String] {
        Array(Set(modelIDs)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    static func colors(for domain: [String]) -> [Color] {
        let modelDomain = domain.filter { $0 != "Other" }
        return domain.map { modelID -> Color in
            guard modelID != "Other" else { return Color.gray }
            let index = modelDomain.firstIndex(of: modelID) ?? 0
            return palette[index % palette.count]
        }
    }

    static func color(for modelID: String, in domain: [String]) -> Color {
        guard modelID != "Other" else { return .gray }
        let modelDomain = domain.filter { $0 != "Other" }
        guard let index = modelDomain.firstIndex(of: modelID) else {
            return .secondary
        }
        return palette[index % palette.count]
    }
}

private enum DashboardFormatters {
    static let hourLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "ha"
        return formatter
    }()

    static let dayLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()
}

private struct DashboardPanelModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(DashboardPalette.panelFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(DashboardPalette.panelStroke, lineWidth: 0.75)
            )
    }
}

private extension View {
    func dashboardPanelStyle(cornerRadius: CGFloat = 12) -> some View {
        modifier(DashboardPanelModifier(cornerRadius: cornerRadius))
    }
}
