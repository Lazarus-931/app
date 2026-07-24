import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ControlPanelTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case dashboard = "Dashboard"
    case models = "Models"
    case integrations = "Integrations"
    case developer = "Developer"
    case settings = "Settings"

    static var allCases: [ControlPanelTab] {
        [.chat, .dashboard, .models, .integrations, .developer]
    }

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .chat:
            "bubble.left.and.bubble.right"
        case .dashboard:
            "chart.bar.xaxis"
        case .models:
            "cube.transparent"
        case .integrations:
            "puzzlepiece.extension"
        case .developer:
            "hammer"
        case .settings:
            "gearshape"
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
    let model: NativModel
    @ObservedObject var navigation: ControlPanelNavigation
    @ObservedObject var runtime: SystemRuntimeMonitor
    @StateObject private var chat = ChatViewModel()
    @StateObject private var dashboard = DashboardViewModel()
    @State private var sidebarSelection: ControlPanelSidebarSelection = .tab(.chat)
    @State private var selectedTab: ControlPanelTab = .chat
    @State private var showsNavigationPanel = false
    @AppStorage("sidebarPinned") private var pinNavigationPanel = true
    @State private var navigationEdgeHovered = false
    @State private var navigationPanelHovered = false
    @State private var navigationPanelHideTask: Task<Void, Never>?
    @State private var isChatConfigurationVisible = false
    @State private var isFullScreen = false
    @State private var isNewChatHovering = false
    private let sidebarItemInsets = EdgeInsets(top: -1, leading: 0, bottom: -1, trailing: 0)

    var body: some View {
        Group {
            if pinNavigationPanel {
                HStack(spacing: 0) {
                    dockedSidebar
                    detailPane
                }
            } else {
                detailPane
                    .overlay(alignment: .topLeading) {
                        floatingSidebarOverlay
                    }
            }
        }
        .frame(minWidth: 1040, minHeight: 600)
        .background {
            ControlPanelWindowStateReader(isFullScreen: $isFullScreen)
                .frame(width: 0, height: 0)
        }
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }

    private var titlebarInsetHeight: CGFloat {
        isFullScreen || selectedTab == .chat ? 0 : 34
    }

    private func updateNavigationPanelVisibility() {
        navigationPanelHideTask?.cancel()
        navigationPanelHideTask = nil

        guard !pinNavigationPanel else {
            return
        }

        if navigationEdgeHovered || navigationPanelHovered {
            guard !showsNavigationPanel else {
                return
            }
            withAnimation(.smooth(duration: 0.38)) {
                showsNavigationPanel = true
            }
        } else {
            navigationPanelHideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled,
                      !navigationEdgeHovered,
                      !navigationPanelHovered
                else {
                    return
                }
                withAnimation(.smooth(duration: 0.3)) {
                    showsNavigationPanel = false
                }
            }
        }
    }

    private var detailPane: some View {
        detail
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: titlebarInsetHeight)
            }
    }

    private var floatingSidebarOverlay: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { hovering in
                    navigationEdgeHovered = hovering
                    updateNavigationPanelVisibility()
                }

            if showsNavigationPanel {
                sidebar
                    .padding(.top, isFullScreen ? 34 : 8)
                    .padding(.leading, 10)
                    .onHover { hovering in
                        navigationPanelHovered = hovering
                        updateNavigationPanelVisibility()
                    }
                    .transition(
                        .move(edge: .leading)
                            .combined(with: .opacity)
                    )
            }
        }
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            sidebarList

            Divider()

            HStack {
                Button {
                    applySidebarSelection(.tab(.settings))
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings")

                Button {
                    pinNavigationPanel.toggle()
                } label: {
                    Image(systemName: pinNavigationPanel ? "pin.fill" : "pin")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(pinNavigationPanel ? Color.accentColor : .secondary)
                .help(pinNavigationPanel ? "Auto-hide the sidebar" : "Keep the sidebar visible")

                Spacer(minLength: 0)

                Button {
                    IssueReport.open(model: model, runtime: runtime)
                } label: {
                    Image(systemName: "ladybug")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Report an issue")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var sidebar: some View {
        sidebarContent
            .frame(width: 268, height: 500)
            .background {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.28), radius: 26, y: 10)
    }

    private var dockedSidebar: some View {
        sidebarContent
            .padding(.top, 8)
            .frame(width: 268)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.nativPanel.ignoresSafeArea())
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 0.5)
                    .ignoresSafeArea()
            }
    }

    private var sidebarList: some View {
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
                        canRename: canRenameRecent(recent),
                        canExport: canExportRecent(recent),
                        onSelect: {
                            applySidebarSelection(recent.selection)
                        },
                        onDelete: {
                            deleteRecentSession(recent)
                        },
                        onRename: { newTitle in
                            renameRecentSession(recent, to: newTitle)
                        },
                        onCopyConversation: {
                            copyRecentConversation(recent)
                        },
                        onExportFile: {
                            exportRecentConversation(recent)
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
        .scrollContentBackground(.hidden)
    }

    private var recentSessions: [ControlPanelRecentSession] {
        chat.sessions
            .map(ControlPanelRecentSession.init(chat:))
            .sorted(by: ControlPanelRecentSession.recencySort)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            detailContent
                .id(selectedTab)
                .transition(.opacity)
        }
        .modifier(ControlPanelDetailSafeArea(isFullScreen: isFullScreen))
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .chat:
                    ChatView(
                        model: model,
                        chat: chat,
                        showsConfiguration: $isChatConfigurationVisible,
                        isFullScreen: isFullScreen
                    )
                case .dashboard:
                    StatsView(model: model, dashboard: dashboard)
                case .models:
                    ModelsView(model: model)
                case .integrations:
                    IntegrationsView(model: model)
                case .developer:
                    DeveloperView(model: model, runtime: runtime)
                case .settings:
                    SettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func applySidebarSelection(_ selection: ControlPanelSidebarSelection) {
        withAnimation(.easeOut(duration: 0.22)) {
            applySidebarSelectionNow(selection)
        }
    }

    private func applySidebarSelectionNow(_ selection: ControlPanelSidebarSelection) {
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

    private func createRecentSession() {
        chat.createSession()
        applySidebarSelection(chat.currentSessionID.map(ControlPanelSidebarSelection.chat) ?? .tab(.chat))
    }

    private func canRenameRecent(_ recent: ControlPanelRecentSession) -> Bool {
        if case .chat = recent.selection {
            return true
        }
        return false
    }

    private func renameRecentSession(_ recent: ControlPanelRecentSession, to newTitle: String) {
        guard case .chat(let sessionID) = recent.selection else {
            return
        }
        chat.renameSession(sessionID, to: newTitle)
    }

    private func canExportRecent(_ recent: ControlPanelRecentSession) -> Bool {
        if case .chat = recent.selection {
            return true
        }
        return false
    }

    private func copyRecentConversation(_ recent: ControlPanelRecentSession) {
        guard case .chat(let sessionID) = recent.selection,
              let text = chat.conversationText(for: sessionID)
        else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportRecentConversation(_ recent: ControlPanelRecentSession) {
        guard case .chat(let sessionID) = recent.selection,
              let text = chat.conversationText(for: sessionID)
        else {
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(recent.title).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
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
        case .tab:
            break
        }
    }

    private func isCurrentRecent(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat(let sessionID):
            return sessionID == chat.currentSessionID
        case .tab:
            return false
        }
    }

    private func isRecentDeleteDisabled(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat(let sessionID):
            return chat.isSessionBusy(sessionID)
        case .tab:
            return false
        }
    }

    private func isRecentSelectionDisabled(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat:
            return false
        case .tab:
            return false
        }
    }

    private var newRecentHelp: String {
        "Create a new chat"
    }

}

private struct ControlPanelWindowStateReader: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> ControlPanelWindowStateReaderView {
        let view = ControlPanelWindowStateReaderView()
        view.onWindowChange = context.coordinator.update(window:)
        return view
    }

    func updateNSView(_ view: ControlPanelWindowStateReaderView, context: Context) {
        context.coordinator.isFullScreen = $isFullScreen
        view.onWindowChange = context.coordinator.update(window:)
        view.reportWindowState()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isFullScreen: $isFullScreen)
    }

    @MainActor
    final class Coordinator {
        var isFullScreen: Binding<Bool>

        init(isFullScreen: Binding<Bool>) {
            self.isFullScreen = isFullScreen
        }

        func update(window: NSWindow?) {
            let newValue = window?.styleMask.contains(.fullScreen) == true
            guard isFullScreen.wrappedValue != newValue else { return }
            isFullScreen.wrappedValue = newValue
        }
    }
}

@MainActor
private final class ControlPanelWindowStateReaderView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportWindowState()

        DispatchQueue.main.async { [weak self] in
            self?.reportWindowState()
        }
    }

    func reportWindowState() {
        onWindowChange?(window)
    }
}

private struct ControlPanelDetailSafeArea: ViewModifier {
    let isFullScreen: Bool

    func body(content: Content) -> some View {
        content.ignoresSafeArea(.container, edges: isFullScreen ? [] : .top)
    }
}

private enum ControlPanelSidebarSelection: Hashable {
    case tab(ControlPanelTab)
    case chat(UUID)
}

private struct ControlPanelRecentSession: Identifiable, Equatable {
    enum ID: Hashable {
        case chat(UUID)
    }

    let id: ID
    let title: String
    let inferenceDevice: String?
    let createdAt: Date
    let updatedAt: Date

    init(chat session: ChatSessionSummary) {
        id = .chat(session.id)
        title = session.title
        inferenceDevice = session.lastInferenceDevice
        createdAt = session.createdAt
        updatedAt = session.updatedAt
    }

    var selection: ControlPanelSidebarSelection {
        switch id {
        case .chat(let sessionID):
            return .chat(sessionID)
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
    let canRename: Bool
    let canExport: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void
    let onCopyConversation: () -> Void
    let onExportFile: () -> Void
    @State private var isHovering = false
    @State private var isDeleteHovering = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var renameFieldFocused: Bool

    private var recentDotColor: Color {
        switch recent.inferenceDevice {
        case "cpu":
            return .orange
        case "gpu":
            return .blue
        default:
            return isCurrent ? Color.accentColor : Color.clear
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            if isRenaming {
                HStack(spacing: 7) {
                    Circle()
                        .fill(recentDotColor)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)

                    TextField("Name", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .focused($renameFieldFocused)
                        .onSubmit {
                            commitRename()
                        }
                        .onExitCommand {
                            isRenaming = false
                        }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button(action: onSelect) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(recentDotColor)
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
            }

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
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                beginRename()
            }
        )
        .onHover { isHovering = $0 }
        .animation(.easeInOut, value: isHovering)
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            .disabled(isSelectionDisabled)

            if canRename {
                Button {
                    beginRename()
                } label: {
                    Label("Rename\u{2026}", systemImage: "pencil")
                }
            }

            if canExport {
                Button {
                    onCopyConversation()
                } label: {
                    Label("Copy Conversation", systemImage: "doc.on.doc")
                }
                Button {
                    onExportFile()
                } label: {
                    Label("Export as Text\u{2026}", systemImage: "square.and.arrow.up")
                }
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(isDeleteDisabled)
        }
    }

    private func beginRename() {
        guard canRename else {
            return
        }
        renameDraft = recent.title
        isRenaming = true
        renameFieldFocused = true
    }

    private func commitRename() {
        onRename(renameDraft)
        isRenaming = false
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
