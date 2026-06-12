import SwiftUI

enum ControlPanelTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case stats = "Stats"
    case settings = "Settings"
    case logs = "Logs"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .chat:
            "bubble.left.and.bubble.right"
        case .stats:
            "chart.bar.xaxis"
        case .settings:
            "gearshape"
        case .logs:
            "doc.text"
        }
    }
}

struct ControlPanelView: View {
    @ObservedObject var model: MLXServerDemoModel
    @StateObject private var chat = ChatViewModel()
    @State private var sidebarSelection: ControlPanelSidebarSelection = .tab(.chat)
    @State private var selectedTab: ControlPanelTab = .chat

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 580)
        .onAppear {
            applySidebarSelection(sidebarSelection)
        }
    }

    private var sidebar: some View {
        List {
            Section {
                ForEach(ControlPanelTab.allCases) { tab in
                    let selection = ControlPanelSidebarSelection.tab(tab)
                    Button {
                        applySidebarSelection(selection)
                    } label: {
                        Label(tab.rawValue, systemImage: tab.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .sidebarRowSelectionStyle(isSelected: sidebarSelection == selection)
                    .buttonStyle(.plain)
                }
            }

            Section {
                ForEach(chat.sessions) { session in
                    let selection = ControlPanelSidebarSelection.chat(session.id)
                    Button {
                        applySidebarSelection(selection)
                    } label: {
                        ControlPanelChatSessionRow(
                            session: session,
                            isCurrent: session.id == chat.currentSessionID,
                            isDisabled: chat.isSending,
                            onDelete: {
                                let deletingSelection = sidebarSelection == .chat(session.id)
                                chat.deleteSession(session.id)
                                if deletingSelection {
                                    applySidebarSelection(chat.currentSessionID.map(ControlPanelSidebarSelection.chat) ?? .tab(.chat))
                                }
                            }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .sidebarRowSelectionStyle(isSelected: sidebarSelection == selection)
                    .buttonStyle(.plain)
                    .disabled(chat.isSending)
                    .opacity(chat.isSending && session.id != chat.currentSessionID ? 0.55 : 1)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
            } header: {
                HStack(spacing: 8) {
                    Text("Recents")

                    Spacer(minLength: 0)

                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            chat.createSession()
                            applySidebarSelection(chat.currentSessionID.map(ControlPanelSidebarSelection.chat) ?? .tab(.chat))
                        }
                    } label: {
                        Image(systemName: "plus")
                            .imageScale(.small)
                    }
                    .buttonStyle(.borderless)
                    .disabled(chat.isSending)
                    .help("New chat")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("MLX Server")
    }

    private var detail: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Group {
                switch selectedTab {
                case .chat:
                    ChatView(model: model, chat: chat)
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
        .ignoresSafeArea(.container, edges: .top)
    }

    private func applySidebarSelection(_ selection: ControlPanelSidebarSelection) {
        switch selection {
        case .tab(let tab):
            sidebarSelection = selection
            selectedTab = tab
        case .chat(let sessionID):
            if chat.sessions.contains(where: { $0.id == sessionID }) {
                chat.selectSession(sessionID)
                sidebarSelection = selection
            } else {
                sidebarSelection = .tab(.chat)
            }
            selectedTab = .chat
        }
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

            Button(model.isRunning ? "Running" : "Start") {
                model.toggleServer()
            }
            .buttonBorderShape(.capsule)
            .buttonStyle(.glassProminent)
            .tint(model.isRunning ? .white : .accentColor)
            .keyboardShortcut("s", modifiers: .command)
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

private enum ControlPanelSidebarSelection: Hashable {
    case tab(ControlPanelTab)
    case chat(UUID)
}

private struct ControlPanelChatSessionRow: View {
    let session: ChatSessionSummary
    let isCurrent: Bool
    let isDisabled: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .help(session.title)
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(isDisabled)
        }
    }

    private var detail: String {
        if isCurrent {
            return "Current"
        }

        return "\(session.messageCount) \(session.messageCount == 1 ? "message" : "messages")"
    }
}

private struct SidebarRowSelectionStyle: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .foregroundStyle(isSelected ? Color.primary : Color.primary)
    }
}

private extension View {
    func sidebarRowSelectionStyle(isSelected: Bool) -> some View {
        modifier(SidebarRowSelectionStyle(isSelected: isSelected))
    }
}

#Preview {
    ControlPanelView(model: .init())
}
