import Charts
import MLXServerKit
import SwiftUI

struct StatsView: View {
    @ObservedObject var model: MLXServerDemoModel
    @ObservedObject var dashboard: DashboardViewModel
    @FocusState private var isModelSearchFocused: Bool

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
        .onChange(of: model.settings.modelSearchPath) { _, _ in
            syncDashboardState(scanModels: true, reloadHistory: false)
        }
        .onChange(of: model.analyticsDatabaseURL) { _, _ in
            syncDashboardState(scanModels: false, reloadHistory: false)
        }
        .onChange(of: model.metrics?.server.loadedModel) { _, _ in
            syncDashboardState(scanModels: false, reloadHistory: false)
        }
        .onChange(of: model.lastMetricsFetchAt) { _, _ in
            syncDashboardState(scanModels: false, reloadHistory: true)
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Analytics")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Monitor token consumption, request volume, and model performance across this workspace.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Circle()
                    .fill(model.isRunning ? DashboardPalette.positive : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(model.isRunning ? "Live" : "Offline")
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
                tint: DashboardPalette.accent
            )
            AnalyticsMetricCard(
                title: "Requests",
                value: compact(totalRequests),
                detail: "\(compact(dashboard.historicalSummary.requestsCompleted)) completed",
                icon: "arrow.up.arrow.down",
                tint: DashboardPalette.indigo
            )
            AnalyticsMetricCard(
                title: "Success rate",
                value: successRateLabel,
                detail: dashboard.historicalSummary.requestsFailed == 0
                    ? "No failed requests"
                    : "\(compact(dashboard.historicalSummary.requestsFailed)) failed",
                icon: "checkmark.circle",
                tint: DashboardPalette.positive
            )
            AnalyticsMetricCard(
                title: "Decode speed",
                value: MLXServerDemoFormatting.rate(
                    dashboard.historicalSummary.averageDecodeTokensPerSecond
                ),
                detail: "Average across requests",
                icon: "gauge.with.dots.needle.67percent",
                tint: DashboardPalette.orange
            )
        }
    }

    private var analyticsGrid: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                TokenUsagePanel(
                    points: dashboard.bucketPoints,
                    modelPoints: dashboard.modelTokenPoints,
                    range: dashboard.selectedRange,
                    showsAllModels: dashboard.appliedModelID == DashboardViewModel.ModelOption.allID
                )
                    .frame(maxWidth: .infinity)
                RequestHealthPanel(
                    points: dashboard.bucketPoints,
                    completed: dashboard.historicalSummary.requestsCompleted,
                    failed: dashboard.historicalSummary.requestsFailed
                )
                .frame(width: 330)
            }

            VStack(spacing: 16) {
                TokenUsagePanel(
                    points: dashboard.bucketPoints,
                    modelPoints: dashboard.modelTokenPoints,
                    range: dashboard.selectedRange,
                    showsAllModels: dashboard.appliedModelID == DashboardViewModel.ModelOption.allID
                )
                RequestHealthPanel(
                    points: dashboard.bucketPoints,
                    completed: dashboard.historicalSummary.requestsCompleted,
                    failed: dashboard.historicalSummary.requestsFailed
                )
            }
        }
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
        return MLXServerDemoFormatting.percent(
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
        MLXServerDemoFormatting.compactCount(value).display
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
                value: MLXServerDemoFormatting.rate(
                    metrics?.summary.averageDecodeTokensPerSecond
                ),
                help: nil
            ),
            SessionCardValue(
                title: "Request speed",
                value: MLXServerDemoFormatting.rate(
                    metrics?.summary.averageRequestTokensPerSecond
                ),
                help: nil
            ),
            SessionCardValue(
                title: "Server uptime",
                value: MLXServerDemoFormatting.duration(metrics?.summary.uptimeSeconds),
                help: nil
            ),
        ]
    }

    private func makeSessionCard(title: String, rawCount: Int?) -> SessionCardValue {
        guard let rawCount else {
            return SessionCardValue(title: title, value: "--", help: nil)
        }
        let formatted = MLXServerDemoFormatting.compactCount(rawCount)
        return SessionCardValue(
            title: title,
            value: formatted.display,
            help: formatted.tooltip
        )
    }

    private func syncDashboardState(scanModels: Bool, reloadHistory: Bool) {
        dashboard.updateAnalyticsDatabaseURL(model.analyticsDatabaseURL)
        dashboard.updatePreferredModelID(model.metrics?.server.loadedModel)
        if scanModels {
            dashboard.scanModels(at: model.settings.modelSearchPath)
        }
        if reloadHistory {
            dashboard.reloadHistorical()
        }
    }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
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
        .dashboardPanelStyle(cornerRadius: 14)
    }
}

private struct TokenUsagePanel: View {
    struct HistogramSegment: Identifiable {
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
                    title: "Token usage",
                    subtitle: showsAllModels
                        ? "Total tokens by model over time"
                        : "Input and output tokens over time"
                )
                Spacer()
                if showsAllModels {
                    Picker("Chart display", selection: $allModelsDisplay) {
                        ForEach(AllModelsDisplay.allCases) { display in
                            Text(display.rawValue).tag(display)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                } else {
                    HStack(spacing: 14) {
                        ChartLegendDot(color: DashboardPalette.accent, title: "Input")
                        ChartLegendDot(color: DashboardPalette.indigo, title: "Output")
                    }
                }
            }

            if points.isEmpty {
                DashboardEmptyChart()
                    .frame(minHeight: 230)
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
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine().foregroundStyle(DashboardPalette.axisGrid)
                        AxisTick().foregroundStyle(DashboardPalette.axisTick)
                        if let raw = value.as(Int.self) {
                            AxisValueLabel(MLXServerDemoFormatting.compactCount(raw).display)
                                .font(.caption2)
                                .foregroundStyle(DashboardPalette.axisText)
                        }
                    }
                }
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
                                    if showsAllModels {
                                        ModelTokenUsageTooltip(
                                            date: hoveredPoint.bucketStart,
                                            points: modelValues(at: hoveredPoint.bucketStart),
                                            granularity: granularity
                                        )
                                    } else {
                                        TokenUsageTooltip(point: hoveredPoint, granularity: granularity)
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
            }
        }
        .padding(18)
        .dashboardPanelStyle(cornerRadius: 14)
    }

    @ChartContentBuilder
    private var usageMarks: some ChartContent {
        if showsAllModels {
            allModelMarks
        } else {
            inputOutputMarks
        }
    }

    @ChartContentBuilder
    private var allModelMarks: some ChartContent {
        if allModelsDisplay == .lines {
            ForEach(modelPoints) { point in
                LineMark(
                    x: .value("Time", point.bucketStart),
                    y: .value("Total tokens", point.totalTokens),
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
                    yStart: .value("Token start", segment.yStart),
                    yEnd: .value("Token end", segment.yEnd)
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
                y: .value("Input tokens", point.promptTokensTotal)
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
                y: .value("Input tokens", point.promptTokensTotal),
                series: .value("Series", "Input")
            )
            .foregroundStyle(DashboardPalette.accent)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Time", point.bucketStart),
                y: .value("Output tokens", point.generatedTokensTotal),
                series: .value("Series", "Output")
            )
            .foregroundStyle(DashboardPalette.indigo)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder
    private var hoverMarks: some ChartContent {
        if let hoveredPoint {
            RuleMark(x: .value("Selected time", hoveredPoint.bucketStart))
                .foregroundStyle(DashboardPalette.axisLabel.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            if showsAllModels {
                ForEach(modelValues(at: hoveredPoint.bucketStart)) { modelPoint in
                    PointMark(
                        x: .value("Selected time", modelPoint.bucketStart),
                        y: .value("Total tokens", modelPoint.totalTokens)
                    )
                    .foregroundStyle(by: .value("Model", modelPoint.modelID))
                    .symbolSize(42)
                }
            } else {
                PointMark(
                    x: .value("Selected time", hoveredPoint.bucketStart),
                    y: .value("Input tokens", hoveredPoint.promptTokensTotal)
                )
                .foregroundStyle(DashboardPalette.accent)
                .symbolSize(48)

                PointMark(
                    x: .value("Selected time", hoveredPoint.bucketStart),
                    y: .value("Output tokens", hoveredPoint.generatedTokensTotal)
                )
                .foregroundStyle(DashboardPalette.indigo)
                .symbolSize(48)
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

    private func modelValues(at date: Date) -> [DashboardViewModel.ModelTokenPoint] {
        modelPoints
            .filter { $0.bucketStart == date }
            .sorted { $0.totalTokens > $1.totalTokens }
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

    private func bucketEnd(after date: Date) -> Date {
        switch granularity {
        case .hour:
            Calendar.current.date(byAdding: .hour, value: 1, to: date) ?? date.addingTimeInterval(3_600)
        case .day:
            Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        }
    }

    private func axisLabel(for date: Date) -> String {
        granularity == .hour
            ? DashboardFormatters.hourLabel.string(from: date).lowercased()
            : DashboardFormatters.dayLabel.string(from: date)
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
              let plotY = proxy.position(forY: tooltipAnchorValue(for: point)) else {
            return nil
        }

        let plotFrame = geometry[plotFrameAnchor]
        let anchor = CGPoint(x: plotFrame.minX + plotX, y: plotFrame.minY + plotY)
        let tooltipSize = CGSize(
            width: showsAllModels ? 230 : 174,
            height: showsAllModels ? min(CGFloat(modelValues(at: point.bucketStart).count) * 25 + 72, 272) : 142
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

    private func tooltipAnchorValue(for point: DashboardViewModel.BucketPoint) -> Int {
        guard showsAllModels else { return point.generatedTokensTotal }
        let values = modelValues(at: point.bucketStart).map(\.totalTokens)
        if allModelsDisplay == .stacked {
            return values.reduce(0, +)
        }
        return values.max() ?? 0
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
                            Text(MLXServerDemoFormatting.integer(point.totalTokens))
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
                Text(MLXServerDemoFormatting.integer(totalTokens))
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
                Text(MLXServerDemoFormatting.integer(point.processedTokensTotal))
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
            Text(MLXServerDemoFormatting.integer(value))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AnalyticsSectionHeader(
                title: "Request health",
                subtitle: "Completion volume and reliability"
            )

            HStack(alignment: .firstTextBaseline) {
                Text(total == 0 ? "--" : MLXServerDemoFormatting.percent(Double(completed) / Double(total)))
                    .font(.system(size: 29, weight: .semibold, design: .rounded).monospacedDigit())
                Text("successful")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if points.isEmpty {
                DashboardEmptyChart()
                    .frame(minHeight: 120)
            } else {
                Chart(points) { point in
                    BarMark(
                        x: .value("Time", point.bucketStart),
                        y: .value("Completed", point.requestsCompleted)
                    )
                    .foregroundStyle(DashboardPalette.positive.gradient)
                    .cornerRadius(2)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 118)
            }

            Divider()

            HStack {
                RequestHealthStat(title: "Completed", value: completed, color: DashboardPalette.positive)
                Spacer()
                RequestHealthStat(title: "Failed", value: failed, color: DashboardPalette.negative)
            }
        }
        .padding(18)
        .dashboardPanelStyle(cornerRadius: 14)
    }

    private var total: Int { completed + failed }
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
            Text(MLXServerDemoFormatting.compactCount(value).display)
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
                Image(systemName: "cpu")
                    .foregroundStyle(DashboardPalette.accent)
                    .frame(width: 28, height: 28)
                    .background(DashboardPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))

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

            tableValue(MLXServerDemoFormatting.compactCount(row.processedTokens).display, width: 105)
            tableValue(MLXServerDemoFormatting.integer(row.totalRequests), width: 90)
            tableValue(row.successRate.map(MLXServerDemoFormatting.percent) ?? "--", width: 85)
            tableValue(MLXServerDemoFormatting.rate(row.averageDecodeTokensPerSecond), width: 105)
            tableValue(MLXServerDemoFormatting.gigabytes(fromBytes: row.peakMemoryBytes), width: 105)
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
                RequestDetailMetric(title: "Prompt tokens", value: MLXServerDemoFormatting.integer(request.promptTokens))
                RequestDetailMetric(title: "Output tokens", value: MLXServerDemoFormatting.integer(request.generatedTokens))
                RequestDetailMetric(title: "Elapsed", value: "\(MLXServerDemoFormatting.seconds(fromMilliseconds: request.requestElapsedMilliseconds))s")
                RequestDetailMetric(title: "Prefill", value: "\(MLXServerDemoFormatting.decimal(request.resolvedPrefillTokensPerSecond)) tok/s")
                RequestDetailMetric(title: "Decode", value: "\(MLXServerDemoFormatting.decimal(request.resolvedDecodeTokensPerSecond)) tok/s")
                RequestDetailMetric(title: "Peak memory", value: MLXServerDemoFormatting.gigabytes(fromBytes: request.peakMemoryBytes))
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
            Text(MLXServerDemoFormatting.integer(request.promptTokens))
        case .completion:
            Text(MLXServerDemoFormatting.integer(request.completionTokens))
        case .prefill:
            Text(MLXServerDemoFormatting.decimal(request.resolvedPrefillTokensPerSecond))
        case .decode:
            Text(MLXServerDemoFormatting.decimal(request.resolvedDecodeTokensPerSecond))
        case .request:
            Text(MLXServerDemoFormatting.decimal(request.requestTokensPerSecond))
        case .elapsed:
            Text(MLXServerDemoFormatting.seconds(fromMilliseconds: request.requestElapsedMilliseconds))
        case .peakMemory:
            Text(MLXServerDemoFormatting.gigabytes(fromBytes: request.peakMemoryBytes))
        }
    }

    private var finishTitle: String {
        if request.status != "completed" {
            return "Failed"
        }

        if let finishReason = request.finishReason,
           !finishReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MLXServerDemoFormatting.titleizedIdentifier(finishReason)
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
        MLXServerDemoFormatting.compactCount(Int(value.rounded())).display
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
                            Text(MLXServerDemoFormatting.compactCount(Int(rawValue.rounded())).display)
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
