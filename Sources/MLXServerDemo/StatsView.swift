import Charts
import MLXServerKit
import SwiftUI

struct StatsView: View {
    @ObservedObject var model: MLXServerDemoModel
    @StateObject private var dashboard = DashboardViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                sessionAnalyticsSection
                historicalAnalyticsSection
            }
            .padding(22)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var sessionAnalyticsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Session analytics")
                .font(.title2.weight(.semibold))

            if let subtitle = sessionSubtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(sessionCards) { card in
                    SessionMetricCard(card: card)
                }
            }
        }
    }

    private var historicalAnalyticsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("All time analytics")
                .font(.title2.weight(.semibold))

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    filtersRow
                    Spacer(minLength: 16)
                    summaryPillsRow
                }

                VStack(alignment: .leading, spacing: 12) {
                    filtersRow
                    summaryPillsRow
                }
            }

            if let localModelError = dashboard.localModelError {
                Text(localModelError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 280), spacing: 16, alignment: .top),
                        GridItem(.flexible(minimum: 280), spacing: 16, alignment: .top),
                    ],
                    alignment: .leading,
                    spacing: 16
                ) {
                    historicalCharts
                }

                LazyVGrid(
                    columns: [GridItem(.flexible(minimum: 280), spacing: 16, alignment: .top)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    historicalCharts
                }
            }

            recentRequestsSection
        }
    }

    @ViewBuilder
    private var historicalCharts: some View {
        HistoricalChartCard(
            title: "Processed tokens",
            help: "Prompt and generated tokens combined over the selected time range."
        ) {
            DashboardTokenChart(
                points: dashboard.bucketPoints,
                range: dashboard.selectedRange,
                metric: .processed
            )
        }

        HistoricalChartCard(
            title: "Generated tokens",
            help: "Model output tokens over the selected time range."
        ) {
            DashboardTokenChart(
                points: dashboard.bucketPoints,
                range: dashboard.selectedRange,
                metric: .generated
            )
        }

        HistoricalChartCard(
            title: "Prompt tokens",
            help: "Input tokens sent to the model over the selected time range."
        ) {
            DashboardTokenChart(
                points: dashboard.bucketPoints,
                range: dashboard.selectedRange,
                metric: .prompt
            )
        }

        HistoricalChartCard(
            title: "Total requests",
            help: "Successful requests are shown in blue. Failed requests are shown in red."
        ) {
            DashboardRequestChart(
                points: dashboard.bucketPoints,
                range: dashboard.selectedRange
            )
        }
    }

    private var filtersRow: some View {
        HStack(spacing: 12) {
            DashboardPickerContainer(title: "Model") {
                Picker("Model", selection: $dashboard.selectedModelID) {
                    ForEach(dashboard.availableModels) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 360)

            DashboardPickerContainer(title: "Range") {
                Picker("Range", selection: $dashboard.selectedRange) {
                    ForEach(DashboardViewModel.RangeOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 180)
        }
    }

    private var recentRequestsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rolling request completion")
                .font(.title2.weight(.semibold))

            DashboardRecentRequestsTable(requests: dashboard.recentRequestEvents)
        }
    }

    private var summaryPillsRow: some View {
        HStack(spacing: 10) {
            SummaryPill(
                title: "Avg request speed",
                value: MLXServerDemoFormatting.rate(
                    dashboard.historicalSummary.averageRequestTokensPerSecond
                )
            )
            SummaryPill(
                title: "Avg decode speed",
                value: MLXServerDemoFormatting.rate(
                    dashboard.historicalSummary.averageDecodeTokensPerSecond
                )
            )
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
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .dashboardPanelStyle(cornerRadius: 10)
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

                            DashboardRecentRequestsDataRow(request: request)
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
            Text(MLXServerDemoFormatting.decimal(request.prefillTokensPerSecond))
        case .decode:
            Text(MLXServerDemoFormatting.decimal(request.decodeTokensPerSecond))
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
        case .model:
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
        case .last7Days, .last30Days, .allTime:
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
        case .last7Days, .last30Days, .allTime:
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
    static let primaryBar = Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
    static let successBar = Color(red: 68 / 255, green: 157 / 255, blue: 187 / 255)
    static let failureBar = Color(red: 181 / 255, green: 51 / 255, blue: 63 / 255)
    static let panelFill = Color(nsColor: .controlBackgroundColor)
    static let panelStroke = Color(nsColor: .separatorColor).opacity(0.6)
    static let axisLabel = Color(nsColor: .tertiaryLabelColor)
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
