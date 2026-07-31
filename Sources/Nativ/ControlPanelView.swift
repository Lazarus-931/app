import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ControlPanelTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case artifacts = "Artifacts"
    case audio = "Audio"
    case dashboard = "Dashboard"
    case system = "System"
    case models = "Models"
    case integrations = "Integrations"
    case developer = "Developer"
    case settings = "Settings"

    static var allCases: [ControlPanelTab] {
        [.chat, .artifacts, .audio, .dashboard, .system, .models, .integrations, .developer]
    }

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .chat:
            "bubble.left.and.bubble.right"
        case .artifacts:
            "photo.on.rectangle.angled"
        case .audio:
            "waveform.badge.mic"
        case .dashboard:
            "chart.bar.xaxis"
        case .system:
            "gauge.open.with.lines.needle.33percent"
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
    @Published private(set) var speechModelDiscoveryRequest = 0
    private var consumedNewChatRequest = 0

    func open(_ tab: ControlPanelTab) {
        requestedTab = tab
    }

    func openSpeechModelDiscovery() {
        speechModelDiscoveryRequest += 1
        requestedTab = .models
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

/// A small pulsing download arrow shown next to the Models sidebar row, with the
/// number of models still downloading beside it.
private struct ModelsDownloadArrow: View {
    let count: Int
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.tint)
                .opacity(pulse ? 0.4 : 1.0)
                .animation(
                    .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.tint)
            }
        }
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        count == 1 ? "A model is downloading" : "\(count) models are downloading"
    }
}

private struct GlobalModelLoadFailureBanner: View {
    let message: String
    let showsOpenModels: Bool
    let onOpenModels: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Model didn’t load")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            if showsOpenModels {
                Button("Open Models", action: onOpenModels)
                    .buttonStyle(.bordered)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Dismiss model loading error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }
}

struct ControlPanelView: View {
    @ObservedObject var model: NativModel
    @ObservedObject var navigation: ControlPanelNavigation
    @ObservedObject var runtime: SystemRuntimeMonitor
    @StateObject private var chat = ChatViewModel()
    @StateObject private var artifacts = ArtifactStore()
    @StateObject private var dashboard = DashboardViewModel()
    @StateObject private var systemMonitor = SystemMonitorStore()
    @ObservedObject private var downloads = HuggingFaceDownloadManager.shared
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
    @State private var isPinnedDropTargeted = false
    @State private var isSessionsDropTargeted = false
    @State private var isSelectingRecents = false
    @State private var selectedRecentIDs: Set<ControlPanelRecentSession.ID> = []
    @State private var pendingDeleteRecent: ControlPanelRecentSession?
    @State private var isConfirmingBulkDelete = false
    @State private var reorderTargetID: ControlPanelRecentSession.ID?
    @State private var reorderInsertAfter = false
    @State private var hoveredFooterControl: FooterControl?
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
        .overlay(alignment: .top) {
            if let notice = model.modelPreloadFailureNotice {
                GlobalModelLoadFailureBanner(
                    message: notice,
                    showsOpenModels: selectedTab != .models,
                    onOpenModels: { navigation.open(.models) },
                    onDismiss: { model.dismissModelPreloadFailureNotice() }
                )
                .padding(.top, 10)
                .padding(.horizontal, 16)
                .task(id: notice) {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    model.dismissModelPreloadFailureNotice()
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.modelPreloadFailureNotice)
        .background {
            ControlPanelWindowStateReader(isFullScreen: $isFullScreen)
                .frame(width: 0, height: 0)
        }
        .onAppear {
            applySidebarSelection(navigation.requestedTab.map(ControlPanelSidebarSelection.tab) ?? sidebarSelection)
            handleNewChatRequest()
            artifacts.onDeleteAttachment = { sessionID, messageID, attachmentID in
                chat.removeAttachment(sessionID: sessionID, messageID: messageID, attachmentID: attachmentID)
            }
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

            HStack(spacing: 4) {
                settingsButton
                pinButton

                Spacer(minLength: 0)

                supportButton
                serverToggleButton
                issueReportMenu
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private var settingsButton: some View {
        footerControl(.settings, tooltip: "Settings") {
            Button {
                applySidebarSelection(.tab(.settings))
            } label: {
                footerIcon(systemName: "gearshape")
            }
            .buttonStyle(.plain)
        }
    }

    private var pinButton: some View {
        footerControl(
            .pin,
            tooltip: pinNavigationPanel ? "Auto-hide the sidebar" : "Keep the sidebar visible"
        ) {
            Button {
                pinNavigationPanel.toggle()
            } label: {
                Image(systemName: pinNavigationPanel ? "pin.fill" : "pin")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(pinNavigationPanel ? Color.accentColor : .secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var supportButton: some View {
        footerControl(.support, tooltip: "Star Nativ on GitHub") {
            Button {
                guard let url = URL(string: "https://github.com/Blaizzy/nativ") else {
                    return
                }
                NSWorkspace.shared.open(url)
            } label: {
                footerIcon(systemName: hoveredFooterControl == .support ? "heart.fill" : "heart")
            }
            .buttonStyle(.plain)
        }
    }

    private var serverToggleButton: some View {
        footerControl(
            .server,
            tooltip: model.isRunning ? "Stop Server" : "Start Server"
        ) {
            Button {
                model.toggleServer()
            } label: {
                footerIcon(systemName: model.isRunning ? "stop.circle" : "play.circle")
            }
            .buttonStyle(.plain)
            .disabled(model.modelSwitchInProgress)
        }
    }

    private var issueReportMenu: some View {
        footerControl(.reportIssue, tooltip: "Report an Issue") {
            Menu {
                ForEach(IssueReportCategory.allCases) { category in
                    Button {
                        IssueReport.open(category: category, model: model, runtime: runtime)
                    } label: {
                        Label(category.displayName, systemImage: category.systemImage)
                    }
                }
            } label: {
                footerIcon(systemName: "ladybug")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(.secondary)
            .foregroundStyle(.secondary)
        }
    }

    private func footerIcon(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    private func footerControl<Content: View>(
        _ control: FooterControl,
        tooltip: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(width: 40, height: 40)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hoveredFooterControl == control ? 0.08 : 0))
            }
            .overlay {
                FooterControlTrackingView(
                    tooltip: tooltip,
                    onHover: { isHovering in
                        updateFooterHover(control, isHovering: isHovering)
                    }
                )
            }
            .contentShape(Rectangle())
            .accessibilityLabel(tooltip)
            .animation(.easeOut(duration: 0.12), value: hoveredFooterControl == control)
    }

    private func updateFooterHover(_ control: FooterControl, isHovering: Bool) {
        if isHovering {
            hoveredFooterControl = control
        } else if hoveredFooterControl == control {
            hoveredFooterControl = nil
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
                        HStack(spacing: 6) {
                            Label(tab.rawValue, systemImage: tab.systemImage)
                            if tab == .models, downloads.activeCount > 0 {
                                ModelsDownloadArrow(count: downloads.activeCount)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .sidebarRowSelectionStyle(isSelected: sidebarSelection == selection)
                    .buttonStyle(.plain)
                    .listRowInsets(sidebarItemInsets)
                }
            }

            Section {
                if pinnedSessions.isEmpty {
                    Label("Drag a chat here to pin", systemImage: "pin")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .listRowInsets(sidebarItemInsets)
                } else {
                    ForEach(pinnedSessions) { recent in
                        draggableRow(recent, isPinnedRow: true)
                            .overlay(alignment: .top) {
                                pinnedInsertionLine(visible: reorderTargetID == recent.id && !reorderInsertAfter && isPinnedDropTargeted)
                            }
                            .overlay(alignment: .bottom) {
                                pinnedInsertionLine(visible: reorderTargetID == recent.id && reorderInsertAfter && isPinnedDropTargeted)
                            }
                            .listRowInsets(sidebarItemInsets)
                    }
                }
            } header: {
                Text("Pinned")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .textCase(nil)
                    .padding(.horizontal, 7)
            }
            .onDrop(of: [.text], isTargeted: $isPinnedDropTargeted) { providers in
                loadDropString(providers) { _ = handlePinDrop([$0]) }
            }

            Section {
                ForEach(unpinnedSessions) { recent in
                    draggableRow(recent, isPinnedRow: false)
                        .overlay(alignment: .top) {
                            pinnedInsertionLine(visible: reorderTargetID == recent.id && !reorderInsertAfter && isSessionsDropTargeted)
                        }
                        .overlay(alignment: .bottom) {
                            pinnedInsertionLine(visible: reorderTargetID == recent.id && reorderInsertAfter && isSessionsDropTargeted)
                        }
                        .listRowInsets(sidebarItemInsets)
                }
            } header: {
                HStack(spacing: 8) {
                    Text("Sessions")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.7))

                    Spacer(minLength: 0)

                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            isSelectingRecents ? exitSelectMode() : enterSelectMode()
                        }
                    } label: {
                        Image(systemName: isSelectingRecents ? "checkmark.circle" : "checklist")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(isSelectingRecents ? Color.accentColor : Color.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help(isSelectingRecents ? "Done selecting" : "Select chats")
                    .disabled(recentSessions.isEmpty)

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
            .onDrop(of: [.text], isTargeted: $isSessionsDropTargeted) { providers in
                loadDropString(providers) { _ = handleUnpinDrop([$0]) }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            if isSelectingRecents {
                bulkSelectionBar
            }
        }
        .alert(
            "Delete chat?",
            isPresented: Binding(
                get: { pendingDeleteRecent != nil },
                set: { if !$0 { pendingDeleteRecent = nil } }
            ),
            presenting: pendingDeleteRecent
        ) { recent in
            Button("Delete", role: .destructive) {
                deleteRecentSession(recent)
                pendingDeleteRecent = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteRecent = nil
            }
        } message: { recent in
            Text("“\(recent.title)” will be permanently deleted.")
        }
        .alert(
            "Delete \(selectedRecentIDs.count) chats?",
            isPresented: $isConfirmingBulkDelete
        ) {
            Button("Delete", role: .destructive) {
                bulkDeleteSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected chats will be permanently deleted.")
        }
    }

    @ViewBuilder
    private func draggableRow(
        _ recent: ControlPanelRecentSession,
        isPinnedRow: Bool
    ) -> some View {
        if isSelectingRecents {
            selectableRow(recent)
        } else if let payload = recent.dragPayload {
            recentSessionRow(recent)
                .onDrag {
                    NSItemProvider(object: payload as NSString)
                } preview: {
                    dragPreview(recent)
                }
                .onDrop(of: [.text], delegate: RowReorderDropDelegate(
                    targetID: recent.id,
                    setTarget: { id, after in
                        if reorderTargetID != id || reorderInsertAfter != after {
                            reorderTargetID = id
                            reorderInsertAfter = after
                        }
                    },
                    onDrop: { draggedPayload, after in
                        handleRowDrop(
                            draggedPayload: draggedPayload,
                            target: recent,
                            insertAfter: after,
                            isPinnedRow: isPinnedRow
                        )
                    }
                ))
        } else {
            recentSessionRow(recent)
        }
    }

    private func handleRowDrop(
        draggedPayload: String,
        target: ControlPanelRecentSession,
        insertAfter: Bool,
        isPinnedRow: Bool
    ) {
        guard let draggedID = UUID(uuidString: draggedPayload),
              chat.sessions.contains(where: { $0.id == draggedID }),
              let targetID = target.chatID,
              draggedID != targetID
        else {
            return
        }
        var order = (isPinnedRow ? pinnedSessions : unpinnedSessions).compactMap(\.chatID)
        order.removeAll { $0 == draggedID }
        if let index = order.firstIndex(of: targetID) {
            order.insert(draggedID, at: insertAfter ? index + 1 : index)
        } else {
            order.append(draggedID)
        }
        reorderTargetID = nil
        reorderInsertAfter = false
        if isPinnedRow {
            chat.applyPinnedOrder(order)
        } else {
            chat.applySessionOrder(order)
        }
    }

    private func dragPreview(_ recent: ControlPanelRecentSession) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left")
                .font(.system(size: 11))
            Text(recent.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
    }

    private func pinnedInsertionLine(visible: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 8)
            .opacity(visible ? 1 : 0)
    }

    private func selectableRow(_ recent: ControlPanelRecentSession) -> some View {
        let isChecked = selectedRecentIDs.contains(recent.id)
        return HStack(spacing: 8) {
            Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isChecked ? Color.accentColor : Color.secondary.opacity(0.6))
            Text(recent.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(.rect)
        .onTapGesture {
            toggleRecentSelection(recent)
        }
        .listRowInsets(sidebarItemInsets)
    }

    private var bulkSelectionBar: some View {
        HStack(spacing: 10) {
            Text(selectedRecentIDs.isEmpty ? "Select chats" : "\(selectedRecentIDs.count) selected")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                bulkTogglePinSelected()
            } label: {
                Image(systemName: allSelectedChatsPinned ? "pin.slash" : "pin")
            }
            .help(allSelectedChatsPinned ? "Unpin selected" : "Pin selected")
            .disabled(!hasSelectedChats)

            Button(role: .destructive) {
                isConfirmingBulkDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete selected")
            .disabled(selectedRecentIDs.isEmpty)

            Button("Done") {
                withAnimation(.snappy(duration: 0.2)) {
                    exitSelectMode()
                }
            }
            .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    @discardableResult
    private func loadDropString(
        _ providers: [NSItemProvider],
        _ handler: @escaping (String) -> Void
    ) -> Bool {
        guard let provider = providers.first else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            if let string = object as? String, !string.isEmpty {
                DispatchQueue.main.async { handler(string) }
            }
        }
        return true
    }

    private func draggedChatID(from items: [String]) -> UUID? {
        for item in items {
            if let id = UUID(uuidString: item),
               chat.sessions.contains(where: { $0.id == id }) {
                return id
            }
        }
        return nil
    }


    @discardableResult
    private func handlePinDrop(_ items: [String]) -> Bool {
        guard let draggedID = draggedChatID(from: items) else {
            return false
        }
        var order = pinnedSessions.compactMap(\.chatID)
        guard !order.contains(draggedID) else {
            return false
        }
        order.append(draggedID)
        reorderTargetID = nil
        reorderInsertAfter = false
        chat.applyPinnedOrder(order)
        return true
    }

    @discardableResult
    private func handleUnpinDrop(_ items: [String]) -> Bool {
        guard let draggedID = draggedChatID(from: items),
              pinnedSessions.contains(where: { $0.chatID == draggedID }) else {
            return false
        }
        reorderTargetID = nil
        reorderInsertAfter = false
        chat.setPinned(draggedID, pinned: false)
        return true
    }

    private func enterSelectMode() {
        selectedRecentIDs = []
        isSelectingRecents = true
    }

    private func exitSelectMode() {
        isSelectingRecents = false
        selectedRecentIDs = []
    }

    private func toggleRecentSelection(_ recent: ControlPanelRecentSession) {
        if selectedRecentIDs.contains(recent.id) {
            selectedRecentIDs.remove(recent.id)
        } else {
            selectedRecentIDs.insert(recent.id)
        }
    }

    private var selectedChats: [ControlPanelRecentSession] {
        recentSessions.filter { $0.isChat && selectedRecentIDs.contains($0.id) }
    }

    private var hasSelectedChats: Bool {
        !selectedChats.isEmpty
    }

    private var allSelectedChatsPinned: Bool {
        hasSelectedChats && selectedChats.allSatisfy(\.pinned)
    }

    private func bulkTogglePinSelected() {
        let shouldPin = !allSelectedChatsPinned
        let ids = selectedChats.compactMap(\.chatID)
        guard !ids.isEmpty else {
            return
        }
        for id in ids {
            chat.setPinned(id, pinned: shouldPin)
        }
        exitSelectMode()
    }

    private func bulkDeleteSelected() {
        let targets = selectedChats
        guard !targets.isEmpty else {
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            for recent in targets {
                deleteRecentSession(recent)
            }
            exitSelectMode()
        }
    }

    private var recentSessions: [ControlPanelRecentSession] {
        chat.sessions
            .map(ControlPanelRecentSession.init(chat:))
            .sorted(by: ControlPanelRecentSession.recencySort)
    }

    private var pinnedSessions: [ControlPanelRecentSession] {
        recentSessions.filter(\.pinned).sorted(by: ControlPanelRecentSession.pinnedSort)
    }

    private var unpinnedSessions: [ControlPanelRecentSession] {
        recentSessions.filter { !$0.pinned }.sorted(by: ControlPanelRecentSession.sessionSort)
    }

    @ViewBuilder
    private func recentSessionRow(_ recent: ControlPanelRecentSession) -> some View {
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
                pendingDeleteRecent = recent
            },
            onRename: { newTitle in
                renameRecentSession(recent, to: newTitle)
            },
            onCopyConversation: {
                copyRecentConversation(recent)
            },
            onExportFile: {
                exportRecentConversation(recent)
            },
            onNewChat: {
                createRecentSession()
            },
            onTogglePin: {
                togglePinRecent(recent)
            }
        )
        .listRowInsets(sidebarItemInsets)
    }

    private func togglePinRecent(_ recent: ControlPanelRecentSession) {
        guard case .chat(let sessionID) = recent.id else {
            return
        }
        chat.setPinned(sessionID, pinned: !recent.pinned)
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
                case .artifacts:
                    ArtifactsView(
                        store: artifacts,
                        onOpenChat: { artifact in
                            applySidebarSelection(.chat(artifact.sessionID))
                            chat.scrollTargetMessageID = artifact.messageID
                        },
                        onUseInChat: { artifact in
                            if let attachment = artifacts.chatAttachment(for: artifact) {
                                chat.stageAttachment(attachment)
                            }
                            applySidebarSelection(.tab(.chat))
                        },
                        onUseAsReference: { artifact in
                            if let attachment = artifacts.chatAttachment(for: artifact) {
                                chat.stageAttachment(attachment)
                            }
                            applySidebarSelection(.tab(.chat))
                        }
                    )
                case .audio:
                    AudioView(
                        model: model,
                        onOpenSpeechModels: {
                            navigation.openSpeechModelDiscovery()
                        }
                    )
                case .dashboard:
                    StatsView(model: model, dashboard: dashboard)
                case .system:
                    SystemMonitorView(store: systemMonitor, menuBarPreferences: .shared)
                case .models:
                    ModelsView(
                        model: model,
                        speechModelDiscoveryRequest: navigation.speechModelDiscoveryRequest
                    )
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

private enum FooterControl {
    case settings
    case pin
    case support
    case server
    case reportIssue
}

private struct FooterControlTrackingView: NSViewRepresentable {
    let tooltip: String
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> FooterControlTrackingNSView {
        FooterControlTrackingNSView(tooltip: tooltip, onHover: onHover)
    }

    func updateNSView(_ view: FooterControlTrackingNSView, context: Context) {
        view.toolTip = tooltip
        view.onHover = onHover
    }
}

@MainActor
private final class FooterControlTrackingNSView: NSView {
    var onHover: (Bool) -> Void
    private var hoverTrackingArea: NSTrackingArea?

    init(tooltip: String, onHover: @escaping (Bool) -> Void) {
        self.onHover = onHover
        super.init(frame: .zero)
        toolTip = tooltip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover(false)
    }
}

private enum ControlPanelSidebarSelection: Hashable {
    case tab(ControlPanelTab)
    case chat(UUID)
}

private struct RowReorderDropDelegate: DropDelegate {
    let targetID: ControlPanelRecentSession.ID
    let setTarget: (ControlPanelRecentSession.ID?, Bool) -> Void
    let onDrop: (String, Bool) -> Void
    private let rowHeight: CGFloat = 30

    func dropEntered(info: DropInfo) {
        setTarget(targetID, info.location.y > rowHeight / 2)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        setTarget(targetID, info.location.y > rowHeight / 2)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        setTarget(nil, false)
    }

    func performDrop(info: DropInfo) -> Bool {
        let insertAfter = info.location.y > rowHeight / 2
        setTarget(nil, false)
        guard let provider = info.itemProviders(for: [.text]).first else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            if let string = object as? String, !string.isEmpty {
                DispatchQueue.main.async {
                    onDrop(string, insertAfter)
                }
            }
        }
        return true
    }
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
    let pinned: Bool
    let pinnedOrder: Int?
    let sessionOrder: Int?

    init(chat session: ChatSessionSummary) {
        id = .chat(session.id)
        title = session.title
        inferenceDevice = session.lastInferenceDevice
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        pinned = session.isPinned
        pinnedOrder = session.pinnedOrder
        sessionOrder = session.sessionOrder
    }

    var chatID: UUID? {
        if case .chat(let sessionID) = id {
            return sessionID
        }
        return nil
    }

    var dragPayload: String? {
        chatID?.uuidString
    }

    var isChat: Bool {
        if case .chat = id {
            return true
        }
        return false
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

    static func pinnedSort(_ lhs: ControlPanelRecentSession, _ rhs: ControlPanelRecentSession) -> Bool {
        switch (lhs.pinnedOrder, rhs.pinnedOrder) {
        case let (left?, right?):
            return left == right ? recencySort(lhs, rhs) : left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return recencySort(lhs, rhs)
        }
    }

    static func sessionSort(_ lhs: ControlPanelRecentSession, _ rhs: ControlPanelRecentSession) -> Bool {
        switch (lhs.sessionOrder, rhs.sessionOrder) {
        case let (left?, right?):
            return left == right ? recencySort(lhs, rhs) : left < right
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        case (nil, nil):
            return recencySort(lhs, rhs)
        }
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
    let onNewChat: () -> Void
    let onTogglePin: () -> Void
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
                Button {
                    if NSEvent.modifierFlags.contains(.shift) {
                        onTogglePin()
                    } else if isSelected {
                        beginRename()
                    } else {
                        onSelect()
                    }
                } label: {
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
        .onHover { isHovering = $0 }
        .animation(.easeInOut, value: isHovering)
        .contextMenu {
            Button {
                onNewChat()
            } label: {
                Label("New", systemImage: "square.and.pencil")
            }

            Divider()

            if canRename {
                Button {
                    beginRename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }

            Button {
                onTogglePin()
            } label: {
                Label(recent.pinned ? "Unpin" : "Pin", systemImage: recent.pinned ? "pin.slash" : "pin")
            }

            Divider()

            if canExport {
                Button {
                    onExportFile()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
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
