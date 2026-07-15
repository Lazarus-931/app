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
    let model: MLXServerModel
    @ObservedObject var navigation: ControlPanelNavigation
    @ObservedObject var runtime: SystemRuntimeMonitor
    @StateObject private var chat = ChatViewModel()
    @StateObject private var imageGeneration = ImageGenerationViewModel()
    @StateObject private var dashboard = DashboardViewModel()
    @State private var sidebarSelection: ControlPanelSidebarSelection = .tab(.chat)
    @State private var selectedTab: ControlPanelTab = .chat
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var isChatConfigurationVisible = true
    @State private var isFullScreen = false
    @State private var isNewChatHovering = false
    private let sidebarItemInsets = EdgeInsets(top: -1, leading: 0, bottom: -1, trailing: 0)

    var body: some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1040, minHeight: 600)
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
                    .listRowInsets(sidebarItemInsets)
                }
            }

            Section {
                ForEach(recentSessions) { recent in
                    ControlPanelRecentSessionRow(
                        recent: recent,
                        isSelected: sidebarSelection == recent.selection,
                        isCurrent: isCurrentRecent(recent),
                        isSelectionDisabled: isRecentSelectionDisabled(recent),
                        isDeleteDisabled: isRecentDeleteDisabled(recent),
                        onSelect: {
                            applySidebarSelection(recent.selection)
                        },
                        onDelete: {
                            deleteRecentSession(recent)
                        }
                    )
                    .listRowInsets(sidebarItemInsets)
                }
            } header: {
                HStack(spacing: 8) {
                    Text("Recents")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.7))

                    Spacer(minLength: 0)

                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            createRecentSession()
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(isNewChatHovering ? Color.primary : Color.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help(newRecentHelp)
                    .padding(.trailing, 4)
                    .onHover { isNewChatHovering = $0 }
                }
                .textCase(nil)
                .padding(.horizontal, 7)
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
        chat.sessions
            .map(ControlPanelRecentSession.init(chat:))
            .sorted(by: ControlPanelRecentSession.recencySort)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Group {
                switch selectedTab {
                case .chat:
                    ChatView(
                        model: model,
                        chat: chat,
                        showsConfiguration: isChatConfigurationVisible
                    )
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

    private func isRecentDeleteDisabled(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat(let sessionID):
            return chat.isSessionBusy(sessionID)
        case .imageGeneration:
            return imageGeneration.isGenerating
        case .tab:
            return false
        }
    }

    private func isRecentSelectionDisabled(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat:
            return false
        case .imageGeneration:
            return imageGeneration.isGenerating
        case .tab:
            return false
        }
    }

    private var newRecentHelp: String {
        "Create a new chat"
    }

    private var header: some View {
        ControlPanelHeader(
            model: model,
            selectedTab: selectedTab,
            splitColumnVisibility: splitColumnVisibility,
            isChatConfigurationVisible: $isChatConfigurationVisible
        )
    }
}

private struct ControlPanelHeader: View {
    @ObservedObject var model: MLXServerModel
    let selectedTab: ControlPanelTab
    let splitColumnVisibility: NavigationSplitViewVisibility
    @Binding var isChatConfigurationVisible: Bool

    var body: some View {
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
            
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isChatConfigurationVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(selectedTab != .chat)
            .help(isChatConfigurationVisible ? "Hide model configuration" : "Show model configuration")
            .accessibilityLabel(
                isChatConfigurationVisible ? "Hide model configuration" : "Show model configuration"
            )
        }
        .padding(.leading, headerLeadingPadding)
        .padding(.trailing, 18)
        .padding(.vertical, 14)
        .animation(.snappy(duration: 0.2), value: splitColumnVisibility)
        .animation(.easeInOut, value: selectedTab)
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
    @ObservedObject var model: MLXServerModel
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

    init(chat session: ChatSessionSummary) {
        id = .chat(session.id)
        title = session.title
        createdAt = session.createdAt
        updatedAt = session.updatedAt
    }

    init(imageGeneration session: ImageGenerationSessionSummary) {
        id = .imageGeneration(session.id)
        title = session.title
        createdAt = session.createdAt
        updatedAt = session.updatedAt
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
    let isSelectionDisabled: Bool
    let isDeleteDisabled: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false
    @State private var isDeleteHovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(isCurrent ? Color.accentColor : Color.clear)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)

                    Text(recent.title)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isSelectionDisabled)
            .help(recent.title)

            if isHovering {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .frame(width: 26, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isDeleteHovering ? Color.red.opacity(0.13) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(isDeleteHovering ? Color.red : Color.secondary)
                .disabled(isDeleteDisabled)
                .help("Delete \(recent.title)")
                .opacity(isHovering && !isDeleteDisabled ? 1 : 0)
                .allowsHitTesting(isHovering && !isDeleteDisabled)
                .onHover { isDeleteHovering = $0 }
            }
        }
        .sidebarRowSelectionStyle(isSelected: isSelected)
        .opacity(isSelectionDisabled && !isCurrent ? 0.55 : 1)
        .onHover { isHovering = $0 }
        .animation(.easeInOut, value: isHovering)
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            .disabled(isSelectionDisabled)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(isDeleteDisabled)
        }
    }
}

private struct SidebarRowSelectionStyle: ViewModifier {
    let isSelected: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 15, weight: .regular))
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
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
            .animation(.easeInOut, value: isHovering)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }
        if isHovering {
            return Color.accentColor.opacity(0.08)
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
