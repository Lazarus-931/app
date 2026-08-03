import NativServerKit
import SwiftUI

struct ToolsSectionView: View {
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel

    var body: some View {
        HubSectionScaffold(
            title: "Tools",
            subtitle: "Capabilities tool-capable models can call."
        ) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 22) {
                toolGroup(title: "Built-in", tools: nativeTools)

                ForEach(enabledServers) { server in
                    let tools = host.tools(forServer: server.id).map {
                        ToolItem(name: $0.name, title: $0.displayName, detail: "")
                    }
                    if !tools.isEmpty {
                        toolGroup(title: server.name, tools: tools)
                    }
                }
            }
        }
    }

    private var enabledServers: [MCPServerConfig] {
        model.settings.mcpServers.filter(\.isEnabled)
    }

    @ViewBuilder
    private func toolGroup(title: String, tools: [ToolItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            ForEach(Array(tools.enumerated()), id: \.element.name) { index, tool in
                if index > 0 { Divider() }
                ToolRow(tool: tool, isOn: binding(for: tool.name))
            }
        }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { !model.settings.disabledToolNames.contains(name) },
            set: { enabled in
                if enabled {
                    model.settings.disabledToolNames.removeAll { $0 == name }
                } else if !model.settings.disabledToolNames.contains(name) {
                    model.settings.disabledToolNames.append(name)
                }
            }
        )
    }

    private var nativeTools: [ToolItem] {
        var definitions: [MLXChatToolDefinition] = []
        definitions += ChatSystemMonitorToolRegistry.definitions()
        definitions += ChatModelLibraryToolRegistry.definitions()
        definitions += ChatServerStatsToolRegistry.definitions()
        definitions += ChatSwitchModelToolRegistry.definitions()
        definitions += ChatImageToolRegistry.definitions(canEdit: false)
        return definitions.map {
            ToolItem(name: $0.function.name, title: $0.function.name, detail: $0.function.description)
        }
    }
}

private struct ToolItem {
    let name: String
    let title: String
    let detail: String
}

private struct ToolRow: View {
    let tool: ToolItem
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                if !tool.detail.isEmpty {
                    Text(tool.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 9)
    }
}
