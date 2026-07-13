import SwiftUI

enum ControlPanelTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case imageGeneration = "Image Generation"
    case dashboard = "Dashboard"
    case settings = "Settings"
    case logs = "Logs"

    static var allCases: [ControlPanelTab] {
        [.chat, .dashboard, .settings, .logs]
    }

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .chat:
            "bubble.left.and.bubble.right"
        case .imageGeneration:
            "photo.on.rectangle"
        case .dashboard:
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
    @StateObject private var imageGeneration = ImageGenerationViewModel()
    @StateObject private var dashboard = DashboardViewModel()
    @State private var sidebarSelection: ControlPanelSidebarSelection = .tab(.chat)
    @State private var selectedTab: ControlPanelTab = .chat
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
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
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        createRecentSession()
                    }
                } label: {
                    Label("New chat", systemImage: "plus")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.accentColor.opacity(0.16))
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(isNewRecentDisabled)
                .help(newRecentHelp)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
            }

            Section("Recents") {
                ForEach(recentSessions) { recent in
                    ControlPanelRecentSessionRow(
                        recent: recent,
                        isSelected: sidebarSelection == recent.selection,
                        isCurrent: isCurrentRecent(recent),
                        isDisabled: isRecentDisabled(recent),
                        onSelect: {
                            applySidebarSelection(recent.selection)
                        },
                        onDelete: {
                            deleteRecentSession(recent)
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("MLX Server")
    }

    private var recentSessions: [ControlPanelRecentSession] {
        let sessions = chat.sessions.map(ControlPanelRecentSession.init(chat:))
        let sortedSessions = sessions.sorted(by: ControlPanelRecentSession.recencySort)

        guard let selectedRecent = sortedSessions.first(where: { $0.selection == sidebarSelection }) else {
            return sortedSessions
        }
        return [selectedRecent] + sortedSessions.filter { $0.id != selectedRecent.id }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Group {
                switch selectedTab {
                case .chat:
                    ChatView(model: model, chat: chat)
                case .imageGeneration:
                    ImageGenerationView(model: model, viewModel: imageGeneration)
                case .dashboard:
                    StatsView(model: model, dashboard: dashboard)
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
        case .imageGeneration(let sessionID):
            if imageGeneration.sessions.contains(where: { $0.id == sessionID }) {
                imageGeneration.selectSession(sessionID)
                sidebarSelection = selection
            } else {
                sidebarSelection = .tab(.imageGeneration)
            }
            selectedTab = .imageGeneration
        }
    }

    private func createRecentSession() {
        chat.createSession()
        applySidebarSelection(chat.currentSessionID.map(ControlPanelSidebarSelection.chat) ?? .tab(.chat))
    }

    private func deleteRecentSession(_ recent: ControlPanelRecentSession) {
        let deletingSelection = sidebarSelection == recent.selection

        switch recent.selection {
        case .chat(let sessionID):
            chat.deleteSession(sessionID)
            if deletingSelection {
                applySidebarSelection(chat.currentSessionID.map(ControlPanelSidebarSelection.chat) ?? .tab(.chat))
            }
        case .imageGeneration(let sessionID):
            imageGeneration.deleteSession(sessionID)
            if deletingSelection {
                applySidebarSelection(
                    imageGeneration.currentSessionID.map(ControlPanelSidebarSelection.imageGeneration)
                        ?? .tab(.imageGeneration)
                )
            }
        case .tab:
            break
        }
    }

    private func isCurrentRecent(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat(let sessionID):
            return sessionID == chat.currentSessionID
        case .imageGeneration(let sessionID):
            return sessionID == imageGeneration.currentSessionID
        case .tab:
            return false
        }
    }

    private func isRecentDisabled(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat:
            return chat.isSending
        case .imageGeneration:
            return imageGeneration.isGenerating
        case .tab:
            return false
        }
    }

    private var isNewRecentDisabled: Bool {
        chat.isSending
    }

    private var newRecentHelp: String {
        "Create a new chat"
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
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(model.isRunning ? "Running" : "Start") {
                model.toggleServer()
            }
            .buttonBorderShape(.capsule)
            .buttonStyle(.glassProminent)
            .tint(model.isRunning ? .white : .accentColor)
            .keyboardShortcut("s", modifiers: .command)
            .fixedSize()
        }
        .padding(.leading, headerLeadingPadding)
        .padding(.trailing, 18)
        .padding(.vertical, 14)
        .animation(.snappy(duration: 0.2), value: splitColumnVisibility)
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

    private var headerLeadingPadding: CGFloat {
        splitColumnVisibility == .detailOnly ? 164 : 18
    }
}

private enum ControlPanelSidebarSelection: Hashable {
    case tab(ControlPanelTab)
    case chat(UUID)
    case imageGeneration(UUID)
}

private struct ControlPanelRecentSession: Identifiable, Equatable {
    enum ID: Hashable {
        case chat(UUID)
        case imageGeneration(UUID)
    }

    let id: ID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let modelKind: SessionModelKind
    let itemCount: Int
    let singularItemName: String
    let pluralItemName: String

    init(chat session: ChatSessionSummary) {
        id = .chat(session.id)
        title = session.title
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        modelKind = .language
        itemCount = session.messageCount
        singularItemName = "message"
        pluralItemName = "messages"
    }

    init(imageGeneration session: ImageGenerationSessionSummary) {
        id = .imageGeneration(session.id)
        title = session.title
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        modelKind = session.modelKind
        itemCount = session.resultCount
        singularItemName = "image"
        pluralItemName = "images"
    }

    var selection: ControlPanelSidebarSelection {
        switch id {
        case .chat(let sessionID):
            return .chat(sessionID)
        case .imageGeneration(let sessionID):
            return .imageGeneration(sessionID)
        }
    }

    static func recencySort(_ lhs: ControlPanelRecentSession, _ rhs: ControlPanelRecentSession) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.updatedAt > rhs.updatedAt
    }
}

private struct ControlPanelRecentSessionRow: View {
    let recent: ControlPanelRecentSession
    let isSelected: Bool
    let isCurrent: Bool
    let isDisabled: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recent.title)
                            .font(.callout.weight(isCurrent ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        HStack(spacing: 6) {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Text(recent.modelKind.badgeTitle)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.12))
                                )
                        }
                    }

                    Spacer(minLength: 0)

                    if isCurrent {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help(recent.title)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isDisabled)
            .help("Delete \(recent.title)")
        }
        .opacity(isDisabled && !isCurrent ? 0.55 : 1)
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }

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

        return "\(recent.itemCount) \(recent.itemCount == 1 ? recent.singularItemName : recent.pluralItemName)"
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
