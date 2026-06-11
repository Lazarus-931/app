import SwiftUI

enum ControlPanelTab: String, CaseIterable, Identifiable {
    case stats = "Stats"
    case settings = "Settings"
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

            Group {
                switch selectedTab {
                case .stats:
                    StatsView(model: model)
                case .settings:
                    SettingsView(model: model)
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
            
            GlassEffectContainer(spacing: 0) {
                GlassTabPicker(selectedTab: $selectedTab)
            }

            Spacer(minLength: 16)

            Button(model.isRunning ? "Stop" : "Start") {
                model.toggleServer()
            }
            .buttonBorderShape(.capsule)
            .buttonStyle(.glassProminent)
            .tint(model.isRunning ? .gray : .accentColor)
            .keyboardShortcut("s", modifiers: .command)
            
            Button {
                
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 18)
        .padding(.trailing, 18)
        .padding(.vertical, 14)
    }

    private var statusSubtitle: String {
        if model.isRunning {
            if model.settingsRequireRestart {
                return "Running | \(model.loadedModelDisplay) | Settings pending"
            }
            return "Running | \(model.loadedModelDisplay)"
        }
        return "Stopped"
    }
}

struct GlassTabPicker: View {
    @Binding var selectedTab: ControlPanelTab
    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ControlPanelTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                .background {
                    if selectedTab == tab {
                        Capsule()
                            .fill(.primary.opacity(0.12))
                            .matchedGeometryEffect(
                                id: "selected-segment",
                                in: selectionNamespace
                            )
                    }
                }
            }
        }
        .padding(1)
        .frame(width: 312)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

#Preview {
    ControlPanelView(model: .init())
}
