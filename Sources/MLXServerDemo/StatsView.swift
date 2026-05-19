import MLXServerKit
import SwiftUI

struct StatsView: View {
    @ObservedObject var model: MLXServerDemoModel

    var body: some View {
        Group {
            if !model.isRunning {
                EmptyStatsView(title: "Server is off", detail: "Metrics paused")
            } else if let metrics = model.metrics {
                metricsContent(metrics)
            } else {
                EmptyStatsView(title: model.unavailableMetricsText, detail: nil)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func metricsContent(_ metrics: MLXServerMetrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StatusStrip(metrics: metrics)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    MetricTile(
                        title: "Processed tokens",
                        value: MLXServerDemoFormatting.compactCount(metrics.summary.totalProcessedTokens).display,
                        help: MLXServerDemoFormatting.compactCount(metrics.summary.totalProcessedTokens).tooltip
                    )
                    MetricTile(
                        title: "Prompt tokens",
                        value: MLXServerDemoFormatting.compactCount(metrics.summary.promptTokensTotal).display,
                        help: MLXServerDemoFormatting.compactCount(metrics.summary.promptTokensTotal).tooltip
                    )
                    MetricTile(
                        title: "Generated tokens",
                        value: MLXServerDemoFormatting.compactCount(metrics.summary.generatedTokensTotal).display,
                        help: MLXServerDemoFormatting.compactCount(metrics.summary.generatedTokensTotal).tooltip
                    )
                    MetricTile(
                        title: "Completed requests",
                        value: MLXServerDemoFormatting.compactCount(metrics.summary.requestsCompleted).display,
                        help: MLXServerDemoFormatting.compactCount(metrics.summary.requestsCompleted).tooltip
                    )
                    MetricTile(
                        title: "Decode speed",
                        value: MLXServerDemoFormatting.rate(metrics.summary.averageDecodeTokensPerSecond),
                        help: nil
                    )
                    MetricTile(
                        title: "Request speed",
                        value: MLXServerDemoFormatting.rate(metrics.summary.averageRequestTokensPerSecond),
                        help: nil
                    )
                }

                HStack(alignment: .top, spacing: 14) {
                    StatsSection(title: "Session", entries: MLXServerDemoStats.sessionEntries(metrics))
                    StatsSection(title: "All-Time", entries: MLXServerDemoStats.allTimeEntries(model.allTimeStats))
                }

                if let latest = metrics.latest {
                    StatsSection(title: "Latest Request", entries: MLXServerDemoStats.latestRequestEntries(latest))
                } else {
                    EmptySection(title: "Latest Request", value: "No completed request yet")
                }

                StatsSection(title: "Runtime", entries: MLXServerDemoStats.runtimeEntries(metrics.server))
            }
            .padding(18)
        }
    }
}

private struct StatusStrip: View {
    let metrics: MLXServerMetrics

    var body: some View {
        HStack(spacing: 14) {
            StatusPill(label: "Model", value: metrics.server.displayLoadedModel)
            StatusPill(label: "Queue", value: "\(metrics.server.requestQueueDepth)")
            StatusPill(label: "In flight", value: "\(metrics.summary.inFlight)")
            StatusPill(label: "Uptime", value: MLXServerDemoFormatting.duration(metrics.summary.uptimeSeconds))
        }
    }
}

private struct StatusPill: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .help(value)
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title3.monospacedDigit())
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .help(help ?? value)
    }
}

private struct StatsSection: View {
    let title: String
    let entries: [StatsEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    StatsRow(entry: entry)
                    if index < entries.count - 1 {
                        Divider()
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct StatsRow: View {
    let entry: StatsEntry

    var body: some View {
        HStack(spacing: 16) {
            Text(entry.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 16)
            Text(entry.value)
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .help(entry.tooltip ?? entry.value)
    }
}

private struct EmptySection: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
    }
}

private struct EmptyStatsView: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
