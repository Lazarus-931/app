import AppKit
import SwiftUI

enum ControlPanelTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case imageGeneration = "Image Generation"
    case dashboard = "Dashboard"
    case models = "Models"
    case logs = "Logs"

    static var allCases: [ControlPanelTab] {
        [.chat, .dashboard, .models, .logs]
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
        case .models:
            "cube.transparent"
        case .logs:
            "doc.text"
        }
    }
}

@MainActor
final class ControlPanelNavigation: ObservableObject {
    @Published private(set) var requestedTab: ControlPanelTab?
    @Published private(set) var newChatRequest = 0
    private var consumedNewChatRequest = 0

    func open(_ tab: ControlPanelTab) {
        requestedTab = tab
    }

    func createChat() {
        newChatRequest += 1
    }

    func consumeNewChatRequest() -> Bool {
        guard consumedNewChatRequest < newChatRequest else {
            return false
        }
        consumedNewChatRequest = newChatRequest
        return true
    }
}

struct ControlPanelView: View {
    @ObservedObject var model: MLXServerDemoModel
    @ObservedObject var navigation: ControlPanelNavigation
    @ObservedObject var runtime: SystemRuntimeMonitor
    @StateObject private var chat = ChatViewModel()
    @StateObject private var imageGeneration = ImageGenerationViewModel()
    @StateObject private var dashboard = DashboardViewModel()
    @State private var sidebarSelection: ControlPanelSidebarSelection = .tab(.chat)
    @State private var selectedTab: ControlPanelTab = .chat
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var isFullScreen = false
    @State private var isNewChatHovering = false

    var body: some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            applySidebarSelection(navigation.requestedTab.map(ControlPanelSidebarSelection.tab) ?? sidebarSelection)
            handleNewChatRequest()
        }
        .onReceive(navigation.$requestedTab) { tab in
            guard let tab else { return }
            applySidebarSelection(.tab(tab))
        }
        .onChange(of: navigation.newChatRequest) { _, _ in
            handleNewChatRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullScreen = false
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
            } header: {
                HStack(spacing: 8) {
                    Text("Recents")

                    Spacer(minLength: 0)

                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            createRecentSession()
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.caption.weight(.semibold))
                            .frame(width: 30, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.accentColor.opacity(isNewChatHovering ? 0.22 : 0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        Color.accentColor.opacity(isNewChatHovering ? 0.32 : 0.08),
                                        lineWidth: 0.5
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(isNewRecentDisabled)
                    .help(newRecentHelp)
                    .padding(.trailing, 4)
                    .onHover { isNewChatHovering = $0 }
                    .animation(.easeOut(duration: 0.12), value: isNewChatHovering)
                }
                .textCase(nil)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            if isFullScreen {
                Color.clear.frame(height: 28)
            }
        }
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
                case .models:
                    ModelsView(model: model)
                case .logs:
                    LogsView(model: model, runtime: runtime)
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

    private func handleNewChatRequest() {
        guard navigation.consumeNewChatRequest() else {
            return
        }
        createRecentSession()
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
                    .font(.title3.weight(.semibold))
                Text(statusSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            serverControlButton
        }
        .padding(.leading, headerLeadingPadding)
        .padding(.trailing, 18)
        .padding(.vertical, 14)
        .animation(.snappy(duration: 0.2), value: splitColumnVisibility)
    }

    private var serverControlButton: some View {
        ServerControlButton(model: model)
    }

    private var statusSubtitle: String {
        if model.isRunning {
            if model.settingsRequireRestart {
                return "Running | \(model.loadedModelDisplay) | Model changes pending"
            }
            return "Running | \(model.loadedModelDisplay)"
        }
        return "Stopped"
    }

    private var headerLeadingPadding: CGFloat {
        splitColumnVisibility == .detailOnly ? 164 : 18
    }
}

struct ServerControlButton: View {
    @ObservedObject var model: MLXServerDemoModel
    @State private var isHovering = false

    var body: some View {
        Button {
            model.toggleServer()
        } label: {
            Label(
                model.isRunning ? "Stop" : "Start",
                systemImage: model.isRunning ? "stop.fill" : "play.fill"
            )
        }
        .labelStyle(.titleAndIcon)
        .buttonBorderShape(.capsule)
        .buttonStyle(.glassProminent)
        .tint(model.isRunning ? (isHovering ? .red : .white) : .accentColor)
        .scaleEffect(isHovering ? 1.04 : 1)
        .shadow(
            color: hoverTint.opacity(isHovering ? 0.28 : 0),
            radius: isHovering ? 10 : 0,
            y: 2
        )
        .keyboardShortcut("s", modifiers: .command)
        .help(model.isRunning ? "Stop server" : "Start server")
        .fixedSize()
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.16), value: isHovering)
    }

    private var hoverTint: Color {
        model.isRunning ? .red : .accentColor
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

    var systemImage: String {
        switch modelKind {
        case .language:
            return "bubble.left"
        case .imageGeneration:
            return "photo"
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
    @State private var isHovering = false
    @State private var isDeleteHovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: recent.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    isSelected
                                        ? Color.accentColor.opacity(0.14)
                                        : Color.secondary.opacity(0.08)
                                )
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(recent.title)
                            .font(.callout.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        HStack(spacing: 6) {
                            if isCurrent {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 5, height: 5)
                            }

                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)

                            Text(recent.modelKind.badgeTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help(recent.title)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(isDeleteHovering ? Color.red.opacity(0.13) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(isDeleteHovering ? Color.red : Color.secondary)
            .disabled(isDisabled)
            .help("Delete \(recent.title)")
            .opacity(isHovering && !isDisabled ? 1 : 0)
            .allowsHitTesting(isHovering && !isDisabled)
            .onHover { isDeleteHovering = $0 }
        }
        .padding(.trailing, 5)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.16)
                        : isHovering ? Color.secondary.opacity(0.07) : Color.clear
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                    lineWidth: 0.5
                )
        )
        .opacity(isDisabled && !isCurrent ? 0.55 : 1)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
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
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                        lineWidth: 0.5
                    )
            )
            .foregroundStyle(Color.primary)
            .contentShape(.rect)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }
        if isHovering {
            return Color.accentColor.opacity(0.10)
        }
        return Color.clear
    }
}

private extension View {
    func sidebarRowSelectionStyle(isSelected: Bool) -> some View {
        modifier(SidebarRowSelectionStyle(isSelected: isSelected))
    }
}

#Preview {
    ControlPanelView(model: .init(), navigation: .init(), runtime: .init())
}
