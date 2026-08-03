import NativServerKit
import SwiftUI

struct MCPSectionView: View {
    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    @State private var editing: MCPServerConfig?
    @State private var showingCatalog = false

    var body: some View {
        HubSectionScaffold(
            title: "MCP",
            subtitle: "Connect Model Context Protocol servers so tool-capable models can use their tools."
        ) {
            HStack(spacing: 8) {
                Button {
                    showingCatalog = true
                } label: {
                    Label("Browse catalog", systemImage: "square.grid.2x2")
                }
                Button {
                    editing = MCPServerConfig(name: "", isEnabled: true)
                } label: {
                    Label("Add your own", systemImage: "plus")
                }
            }
        } content: {
            if model.settings.mcpServers.isEmpty {
                HubEmptyHint(
                    icon: "server.rack",
                    text: "No servers yet. Add your own, or browse the community catalog of approved servers."
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.settings.mcpServers.enumerated()), id: \.element.id) { index, server in
                        if index > 0 { Divider() }
                        MCPServerRow(
                            server: server,
                            state: host.states[server.id],
                            onToggle: { toggle(server) },
                            onReconnect: { host.reconnect(server.id) },
                            onEdit: { editing = server },
                            onDelete: { delete(server) }
                        )
                    }
                }
            }
        }
        .sheet(item: $editing) { server in
            MCPServerEditor(server: server) { saved in
                save(saved)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .sheet(isPresented: $showingCatalog) {
            MCPCatalogView(
                installedNames: Set(model.settings.mcpServers.map(\.name))
            ) { entry in
                save(entry.makeConfig())
            }
        }
    }

    private func toggle(_ server: MCPServerConfig) {
        guard let i = model.settings.mcpServers.firstIndex(where: { $0.id == server.id }) else { return }
        model.settings.mcpServers[i].isEnabled.toggle()
    }

    private func delete(_ server: MCPServerConfig) {
        model.settings.mcpServers.removeAll { $0.id == server.id }
    }

    private func save(_ server: MCPServerConfig) {
        if let i = model.settings.mcpServers.firstIndex(where: { $0.id == server.id }) {
            model.settings.mcpServers[i] = server
        } else {
            model.settings.mcpServers.append(server)
        }
    }
}

// MARK: - Server row

private struct MCPServerRow: View {
    let server: MCPServerConfig
    let state: MCPServerConnectionState?
    let onToggle: () -> Void
    let onReconnect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name.isEmpty ? "Untitled server" : server.name)
                    .font(.system(size: 13, weight: .medium))
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if server.isEnabled {
                Button(action: onReconnect) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reconnect")
            }
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Edit")
            Menu {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            Toggle("", isOn: Binding(get: { server.isEnabled }, set: { _ in onToggle() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 11)
    }

    private var statusColor: Color {
        switch state {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        case .disabled, .none: Color(nsColor: .tertiaryLabelColor)
        }
    }

    private var statusText: String {
        switch state {
        case .connected(let count): "\(count) tool\(count == 1 ? "" : "s")"
        case .connecting: "Connecting\u{2026}"
        case .failed(let message): message.isEmpty ? "Failed to connect" : message
        case .disabled: "Off"
        case .none: server.isEnabled ? "Not connected" : "Off"
        }
    }
}

// MARK: - Add / edit overlay

private struct MCPServerJSON: Codable {
    var name: String
    var command: String
    var arguments: [String]
    var environment: [String: String]
    var isEnabled: Bool
}

private struct MCPServerEditor: View {
    @State var server: MCPServerConfig
    let onSave: (MCPServerConfig) -> Void
    let onCancel: () -> Void

    @State private var editingJSON = false
    @State private var jsonText = ""
    @State private var jsonError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(server.name.isEmpty ? "New MCP Server" : "Edit MCP Server")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Toggle("Edit as JSON", isOn: $editingJSON)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: editingJSON) { _, on in
                        if on { jsonText = currentJSON() } else { applyJSON() }
                    }
            }

            if editingJSON {
                TextEditor(text: $jsonText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 220)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                if let jsonError {
                    Text(jsonError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            } else {
                field("Name") {
                    TextField("e.g. filesystem", text: $server.name)
                        .textFieldStyle(.roundedBorder)
                }
                field("Command") {
                    TextField("e.g. npx", text: $server.command)
                        .textFieldStyle(.roundedBorder)
                }
                field("Arguments (one per line)") {
                    TextEditor(text: argumentsText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 70)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                }
                field("Environment (KEY=VALUE per line)") {
                    TextEditor(text: environmentText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    if editingJSON { applyJSON() }
                    guard jsonError == nil else { return }
                    onSave(server)
                }
                .buttonStyle(.borderedProminent)
                .disabled(server.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            content()
        }
    }

    private var argumentsText: Binding<String> {
        Binding(
            get: { server.arguments.joined(separator: "\n") },
            set: { server.arguments = $0.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
        )
    }

    private var environmentText: Binding<String> {
        Binding(
            get: { server.environment.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n") },
            set: { raw in
                var env: [String: String] = [:]
                for line in raw.split(separator: "\n") {
                    guard let eq = line.firstIndex(of: "=") else { continue }
                    let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                    let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { env[key] = value }
                }
                server.environment = env
            }
        )
    }

    private func currentJSON() -> String {
        let payload = MCPServerJSON(
            name: server.name,
            command: server.command,
            arguments: server.arguments,
            environment: server.environment,
            isEnabled: server.isEnabled
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func applyJSON() {
        guard let data = jsonText.data(using: .utf8) else { return }
        do {
            let payload = try JSONDecoder().decode(MCPServerJSON.self, from: data)
            server.name = payload.name
            server.command = payload.command
            server.arguments = payload.arguments
            server.environment = payload.environment
            server.isEnabled = payload.isEnabled
            jsonError = nil
        } catch {
            jsonError = "Invalid JSON: \(error.localizedDescription)"
        }
    }
}

// MARK: - Community catalog

struct MCPCatalogEntry: Identifiable {
    let id = UUID()
    let name: String
    let summary: String
    let command: String
    let arguments: [String]

    func makeConfig() -> MCPServerConfig {
        MCPServerConfig(name: name, command: command, arguments: arguments, isEnabled: true)
    }
}

private let mcpCatalog: [MCPCatalogEntry] = [
    .init(name: "filesystem", summary: "Read and write files in allowed folders.",
          command: "npx", arguments: ["-y", "@modelcontextprotocol/server-filesystem", "."]),
    .init(name: "git", summary: "Inspect and operate on Git repositories.",
          command: "uvx", arguments: ["mcp-server-git"]),
    .init(name: "github", summary: "Search and manage GitHub issues, PRs, and code.",
          command: "npx", arguments: ["-y", "@modelcontextprotocol/server-github"]),
    .init(name: "fetch", summary: "Fetch and read web pages as markdown.",
          command: "uvx", arguments: ["mcp-server-fetch"]),
    .init(name: "memory", summary: "A persistent knowledge graph the model can recall.",
          command: "npx", arguments: ["-y", "@modelcontextprotocol/server-memory"]),
    .init(name: "sqlite", summary: "Query and edit a local SQLite database.",
          command: "uvx", arguments: ["mcp-server-sqlite", "--db-path", "database.db"]),
]

private struct MCPCatalogView: View {
    let installedNames: Set<String>
    let onAdd: (MCPCatalogEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Community catalog")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Approved servers. Adding one launches it locally the first time you connect.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(mcpCatalog.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).font(.system(size: 13, weight: .medium))
                                Text(entry.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            if installedNames.contains(entry.name) {
                                Text("Added").font(.system(size: 11)).foregroundStyle(.secondary)
                            } else {
                                Button("Add") { onAdd(entry) }
                            }
                        }
                        .padding(.vertical, 11)
                        .padding(.horizontal, 20)
                    }
                }
            }
        }
        .frame(width: 520, height: 420)
    }
}
