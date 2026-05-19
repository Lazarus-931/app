import SwiftUI

enum ControlPanelTab: String, CaseIterable, Identifiable {
    case stats = "Stats"
    case logs = "Logs"

    var id: String { rawValue }
}

struct ControlPanelView: View {
    @ObservedObject var model: MLXServerDemoModel
    @State private var selectedTab: ControlPanelTab = .stats

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $selectedTab) {
                ForEach(ControlPanelTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .padding(.vertical, 12)

            Divider()

            Group {
                switch selectedTab {
                case .stats:
                    StatsView(model: model)
                case .logs:
                    LogsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.isRunning ? Color.green : Color.secondary.opacity(0.55))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text("MLX Server")
                    .font(.headline)
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 16)

            Button(model.isRunning ? "Stop Server" : "Start Server") {
                model.toggleServer()
            }
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var statusSubtitle: String {
        if model.isRunning {
            return "Running | \(model.loadedModelDisplay)"
        }
        return "Stopped"
    }
}
