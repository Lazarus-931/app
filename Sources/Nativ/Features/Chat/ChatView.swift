import AppKit
import Foundation
import NativServerKit
import SwiftUI
import Textual
import UniformTypeIdentifiers

struct ChatView: View {
    private enum Layout {
        static let contentMaxWidth: CGFloat = 860
        static let horizontalPadding: CGFloat = 24
    }

    @ObservedObject var model: NativModel
    @ObservedObject var chat: ChatViewModel
    let showsConfiguration: Bool
    @State private var transcriptScrollPosition = ScrollPosition(edge: .bottom)
    @State private var composerHeight: CGFloat = 0
    @State private var followsLatestMessage = true

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ChatStatusBar(
                    isRunning: model.isRunning,
                    selectedModelID: selectedModelID,
                    loadedModel: model.loadedModelDisplay,
                    settingsRequireRestart: model.settingsRequireRestart
                )

                Divider()

                transcript
                    .overlay(alignment: .bottom) {
                        ChatComposer(
                            viewModel: chat,
                            unavailableReason: unavailableReason,
                            canSend: canSend,
                            onSend: {
                                chat.send(using: model)
                            }
                        )
                        .frame(maxWidth: Layout.contentMaxWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Layout.horizontalPadding)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            let isInitialMeasurement = composerHeight == 0
                            composerHeight = height
                            if isInitialMeasurement {
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(50))
                                    transcriptScrollPosition.scrollTo(edge: .bottom)
                                }
                            }
                        }
                    }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

            if showsConfiguration {
                Divider()

                ChatConfigurationView(
                    settings: $model.settings,
                    settingsRequireRestart: model.settingsRequireRestart,
                    onReset: model.resetSettings
                )
                .frame(width: 320)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var selectedModelID: String? {
        model.settings.normalized().languageModelID
    }

    private var canSend: Bool {
        model.settings.structuredOutputValidationError == nil
            && chat.canSend(isRunning: model.isRunning, selectedModelID: selectedModelID)
    }

    private var unavailableReason: String? {
        chat.unavailableReason(isRunning: model.isRunning, selectedModelID: selectedModelID)
            ?? model.settings.structuredOutputValidationError
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if chat.messages.isEmpty {
                    ChatEmptyTranscriptView(
                        isRunning: model.isRunning,
                        selectedModelID: selectedModelID
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
                } else {
                    ForEach(chat.messages) { message in
                        ChatMessageRow(message: message)
                            .id(message.id)
                    }
                }
            }
            .frame(maxWidth: Layout.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.top, 18)
            .padding(.bottom, max(18, composerHeight))
        }
        .scrollPosition($transcriptScrollPosition)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 160
        } action: { _, isNearBottom in
            followsLatestMessage = isNearBottom
        }
        .onChange(of: chat.scrollToken) { _, _ in
            if followsLatestMessage {
                transcriptScrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: chat.currentSessionID) { _, _ in
            followsLatestMessage = true
            transcriptScrollPosition.scrollTo(edge: .bottom)
        }
        .onAppear {
            followsLatestMessage = true
            transcriptScrollPosition.scrollTo(edge: .bottom)
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var sessions: [ChatSessionSummary] = []
    @Published private(set) var currentSessionID: UUID?
    @Published private(set) var messages: [ChatTranscriptMessage] = []
    @Published private(set) var pendingImageAttachments: [ChatImageAttachment] = []
    @Published var draft = ""
    @Published private(set) var isSending = false
    @Published private(set) var sendingStartedAt: Date?
    @Published private(set) var scrollToken = 0

    private let client = NativChatClient()
    private let sessionStore = ChatSessionStore()
    private var activeTask: Task<Void, Never>?
    private var storedSessions: [ChatSession] = []
    private var currentSession: ChatSession?

    init() {
        storedSessions = sessionStore.loadSessions()
        pruneRedundantEmptySessions()
        if let latestSession = storedSessions.sorted(by: ChatSession.recencySort).first {
            applyCurrentSession(latestSession)
        } else {
            createSession()
        }
    }

    deinit {
        activeTask?.cancel()
    }

    func canSend(isRunning: Bool, selectedModelID: String?) -> Bool {
        isRunning
            && selectedModelID?.isEmpty == false
            && !isSending
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !pendingImageAttachments.isEmpty)
    }

    func unavailableReason(isRunning: Bool, selectedModelID: String?) -> String? {
        if !isRunning {
            return "Server is stopped."
        }
        if selectedModelID?.isEmpty != false {
            return "Select a model in Models."
        }
        if isSending {
            return "Working..."
        }
        return nil
    }

    func createSession() {
        guard !isSending else {
            return
        }

        if canReuseCurrentEmptySession {
            if let currentSession {
                applyCurrentSession(currentSession)
            }
            return
        }

        let createdAt = Date()
        let session = ChatSession(
            id: UUID(),
            title: ChatSession.timestampTitle(for: createdAt),
            createdAt: createdAt,
            updatedAt: createdAt,
            messages: []
        )

        storedSessions.append(session)
        pruneRedundantEmptySessions()
        sessionStore.saveSession(session)
        draft = ""
        pendingImageAttachments.removeAll()
        applyCurrentSession(session)
    }

    func selectSession(_ sessionID: UUID) {
        guard !isSending, sessionID != currentSessionID else {
            return
        }

        if let session = storedSessions.first(where: { $0.id == sessionID }) {
            draft = ""
            pendingImageAttachments.removeAll()
            applyCurrentSession(session)
            return
        }

        if let session = sessionStore.loadSession(id: sessionID) {
            upsertStoredSession(session)
            draft = ""
            pendingImageAttachments.removeAll()
            applyCurrentSession(session)
        }
    }

    func deleteSession(_ sessionID: UUID) {
        guard !isSending else {
            return
        }

        storedSessions.removeAll { $0.id == sessionID }
        sessionStore.deleteSession(id: sessionID)
        pruneRedundantEmptySessions()

        guard sessionID == currentSessionID else {
            refreshSessionList()
            return
        }

        draft = ""
        pendingImageAttachments.removeAll()

        if let nextSession = storedSessions.sorted(by: ChatSession.recencySort).first {
            applyCurrentSession(nextSession)
        } else {
            currentSession = nil
            currentSessionID = nil
            messages = []
            createSession()
        }
    }

    func send(using appModel: NativModel) {
        let settings = appModel.settings.normalized()
        guard canSend(isRunning: appModel.isRunning, selectedModelID: settings.languageModelID),
              let modelID = settings.languageModelID,
              currentSession != nil
        else {
            return
        }

        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageAttachments = pendingImageAttachments
        draft = ""
        pendingImageAttachments.removeAll()

        let userMessage = ChatTranscriptMessage(
            role: .user,
            content: prompt,
            modelID: modelID,
            imageAttachments: imageAttachments
        )
        messages.append(userMessage)
        persistCurrentSession(updateTimestamp: true)

        var requestMessages = messages.compactMap(\.apiMessage)
        if !settings.systemPrompt.isEmpty {
            requestMessages.insert(
                MLXChatMessage(role: "system", content: settings.systemPrompt),
                at: 0
            )
        }
        let assistantID = UUID()
        messages.append(ChatTranscriptMessage(
            id: assistantID,
            role: .assistant,
            content: "",
            modelID: modelID,
            isStreaming: true,
            isThinkingEnabled: settings.thinkingEnabled
        ))
        sendingStartedAt = Date()
        isSending = true
        bumpScroll()

        let request = MLXChatCompletionRequest(
            model: modelID,
            messages: requestMessages,
            maxTokens: settings.maxTokens,
            temperature: settings.temperature,
            topK: settings.topK,
            topP: settings.topP,
            minP: settings.minP,
            repetitionPenalty: settings.repetitionPenaltyEnabled ? settings.repetitionPenalty : nil,
            enableThinking: settings.thinkingEnabled,
            thinkingBudget: settings.thinkingEnabled && settings.thinkingBudgetEnabled
                ? settings.thinkingBudget
                : nil,
            thinkingStartToken: settings.thinkingEnabled ? settings.thinkingStartToken : nil,
            thinkingEndToken: settings.thinkingEnabled ? settings.thinkingEndToken : nil,
            responseFormat: settings.chatResponseFormat,
            stream: true
        )

        activeTask?.cancel()
        activeTask = Task { @MainActor [weak self, weak appModel] in
            guard let self else {
                return
            }

            do {
                let completion = try await client.streamChat(request, onEvent: { [weak self] event in
                    await MainActor.run {
                        self?.append(event: event, to: assistantID)
                    }
                })
                finishAssistantMessage(
                    assistantID,
                    fallbackContent: completion.content,
                    fallbackReasoningContent: completion.reasoningContent,
                    responseMetrics: ChatResponseMetrics(completion: completion),
                    isCancelled: false
                )
                appModel?.refreshMetricsIfRunning(force: true)
            } catch is CancellationError {
                finishAssistantMessage(
                    assistantID,
                    fallbackContent: "Response cancelled.",
                    fallbackReasoningContent: nil,
                    responseMetrics: nil,
                    isCancelled: true
                )
            } catch {
                failAssistantMessage(assistantID, error: error)
                appModel?.refreshMetricsIfRunning(force: true)
            }

            isSending = false
            sendingStartedAt = nil
            activeTask = nil
            bumpScroll()
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    func chooseImageAttachments() {
        guard !isSending else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]

        guard panel.runModal() == .OK else {
            return
        }

        let attachments = panel.urls.compactMap { url in
            try? ChatImageAttachment(contentsOf: url)
        }
        guard !attachments.isEmpty else {
            return
        }

        pendingImageAttachments.append(contentsOf: attachments)
    }

    func removePendingImageAttachment(_ id: UUID) {
        pendingImageAttachments.removeAll { $0.id == id }
    }

    func clear() {
        activeTask?.cancel()
        activeTask = nil
        isSending = false
        sendingStartedAt = nil
        draft = ""
        pendingImageAttachments.removeAll()
        messages.removeAll()
        persistCurrentSession(updateTimestamp: true)
        bumpScroll()
    }

    private func append(event: MLXChatStreamDelta, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let reasoningContent = event.reasoningContent {
            messages[index].reasoningContent.append(reasoningContent)
        }
        if let content = event.content {
            if !content.isEmpty,
               !messages[index].reasoningContent.isEmpty,
               messages[index].thinkingDuration == nil {
                messages[index].thinkingDuration = Date().timeIntervalSince(messages[index].createdAt)
            }
            messages[index].content.append(content)
        }
        bumpScroll()
    }

    private func finishAssistantMessage(
        _ id: UUID,
        fallbackContent: String,
        fallbackReasoningContent: String?,
        responseMetrics: ChatResponseMetrics?,
        isCancelled: Bool
    ) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }

        messages[index].isStreaming = false
        if messages[index].content.isEmpty {
            messages[index].content = fallbackContent
        }
        if messages[index].reasoningContent.isEmpty,
           let fallbackReasoningContent {
            messages[index].reasoningContent = fallbackReasoningContent
        }
        if !messages[index].reasoningContent.isEmpty,
           messages[index].thinkingDuration == nil {
            messages[index].thinkingDuration = Date().timeIntervalSince(messages[index].createdAt)
        }
        if isCancelled,
           messages[index].content == fallbackContent,
           messages[index].reasoningContent.isEmpty {
            messages[index].role = .error
        }
        messages[index].responseMetrics = responseMetrics?.hasVisibleValues == true
            ? responseMetrics
            : nil
        persistCurrentSession(updateTimestamp: true)
    }

    private func failAssistantMessage(_ id: UUID, error: Error) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            messages.append(ChatTranscriptMessage(role: .error, content: error.localizedDescription))
            persistCurrentSession(updateTimestamp: true)
            return
        }

        messages[index].role = .error
        messages[index].content = error.localizedDescription
        messages[index].isStreaming = false
        if !messages[index].reasoningContent.isEmpty,
           messages[index].thinkingDuration == nil {
            messages[index].thinkingDuration = Date().timeIntervalSince(messages[index].createdAt)
        }
        persistCurrentSession(updateTimestamp: true)
    }

    private func bumpScroll() {
        scrollToken += 1
    }

    private func applyCurrentSession(_ session: ChatSession) {
        currentSession = session
        currentSessionID = session.id
        messages = session.messages
        refreshSessionList()
        bumpScroll()
    }

    private func persistCurrentSession(updateTimestamp: Bool) {
        guard var session = currentSession else {
            return
        }

        session.messages = messages
        session.title = ChatSession.defaultTitle(for: messages, createdAt: session.createdAt)
        if updateTimestamp {
            session.updatedAt = Date()
        }

        currentSession = session
        upsertStoredSession(session)
        sessionStore.saveSession(session)
        refreshSessionList()
    }

    private func upsertStoredSession(_ session: ChatSession) {
        if let index = storedSessions.firstIndex(where: { $0.id == session.id }) {
            storedSessions[index] = session
        } else {
            storedSessions.append(session)
        }
    }

    private func refreshSessionList() {
        sessions = storedSessions
            .map(\.summary)
            .sorted(by: ChatSessionSummary.recencySort)
    }

    private var canReuseCurrentEmptySession: Bool {
        guard let currentSession else {
            return false
        }

        return currentSession.messages.isEmpty
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pendingImageAttachments.isEmpty
    }

    private func pruneRedundantEmptySessions() {
        let sortedSessions = storedSessions.sorted(by: ChatSession.recencySort)
        var seenIDs = Set<UUID>()
        var keptSessions: [ChatSession] = []
        var keptEmptySession = false
        var removedSessionIDs: [UUID] = []

        for session in sortedSessions {
            guard seenIDs.insert(session.id).inserted else {
                removedSessionIDs.append(session.id)
                continue
            }

            if session.messages.isEmpty {
                if keptEmptySession {
                    removedSessionIDs.append(session.id)
                    continue
                }
                keptEmptySession = true
            }

            keptSessions.append(session)
        }

        storedSessions = keptSessions
        for sessionID in removedSessionIDs {
            sessionStore.deleteSession(id: sessionID)
        }
    }
}

private struct ChatStatusBar: View {
    let isRunning: Bool
    let selectedModelID: String?
    let loadedModel: String
    let settingsRequireRestart: Bool

    var body: some View {
        HStack(spacing: 10) {
            ChatStatusPill(
                label: "Server",
                value: isRunning ? "Running" : "Stopped",
                systemImage: isRunning ? "checkmark.circle.fill" : "circle"
            )
            ChatStatusPill(
                label: "Selected",
                value: selectedModelID ?? "None",
                systemImage: "cpu"
            )
            ChatStatusPill(
                label: "Loaded",
                value: loadedModel,
                systemImage: "memorychip"
            )

            if settingsRequireRestart {
                ChatStatusPill(label: "Settings", value: "Pending restart", systemImage: "arrow.clockwise")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

private struct ChatStatusPill: View {
    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(label)
                .foregroundStyle(.secondary)

            Text(displayValue)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .help(value)
    }

    private var displayValue: String {
        NativFormatting.truncateModelName(value, maxLength: 34)
    }
}

private struct ChatMessageRow: View {
    let message: ChatTranscriptMessage
    @State private var didCopyResponse = false
    @State private var isHoveringMessage = false

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            if !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: contentStackAlignment, spacing: 6) {
                if !message.imageAttachments.isEmpty {
                    ChatImageAttachmentStack(
                        attachments: message.imageAttachments,
                        isUserMessage: message.role == .user
                    )
                }

                if showsThinkingBubble {
                    ChatThinkingBubble(
                        content: message.reasoningContent,
                        isThinking: message.isStreaming && message.content.isEmpty,
                        thinkingDuration: message.thinkingDuration
                    )
                }

                if showsTextContent {
                    textBubble
                }
            }

            if let responseMetrics {
                ChatResponseMetricsRow(metrics: responseMetrics)
            }

            if showsCopyAction {
                HStack(spacing: 8) {
                    ChatCopyResponseButton(
                        didCopy: didCopyResponse,
                        onCopy: copyResponse
                    )

                    Text(message.createdAt, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .opacity(isHoveringMessage || didCopyResponse ? 1 : 0)
                .accessibilityHidden(!isHoveringMessage && !didCopyResponse)
            }
        }
        .frame(maxWidth: .infinity, alignment: rowAlignment)
        .contentShape(.rect)
        .onHover { isHoveringMessage = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHoveringMessage)
    }

    @ViewBuilder
    private var textBubble: some View {
        Group {
            if usesCompactBubble {
                ChatMessageText(
                    content: displayContent,
                    rendersMarkdown: rendersMarkdown,
                    isStreaming: message.isStreaming
                )
                .lineSpacing(2)
                .fixedSize(horizontal: true, vertical: false)
            } else {
                ChatMessageText(
                    content: displayContent,
                    rendersMarkdown: rendersMarkdown,
                    isStreaming: message.isStreaming
                )
                .lineSpacing(2)
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, alignment: alignment)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.body)
        .padding(.horizontal, message.role == .assistant ? 0 : 12)
        .padding(.vertical, message.role == .assistant ? 3 : 9)
        .foregroundStyle(foregroundStyle)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: message.role == .error ? 1 : 0.5)
        )
    }

    private var title: String {
        switch message.role {
        case .user:
            return ""
        case .assistant:
            return message.modelID.map { NativFormatting.truncateModelName($0, maxLength: 42) } ?? "Assistant"
        case .error:
            return "Error"
        }
    }

    private var rowAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var alignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var textAlignment: TextAlignment {
        message.role == .user ? .trailing : .leading
    }

    private var contentStackAlignment: HorizontalAlignment {
        message.role == .user ? .trailing : .leading
    }

    private var displayContent: String {
        message.content.isEmpty ? " " : message.content
    }

    private var usesCompactBubble: Bool {
        !displayContent.contains(where: \.isNewline)
            && displayContent.count <= 72
    }

    private var showsTextContent: Bool {
        !message.content.isEmpty
            || (!showsThinkingBubble && (message.imageAttachments.isEmpty || message.isStreaming))
    }

    private var showsThinkingBubble: Bool {
        guard message.role == .assistant else {
            return false
        }
        return !message.reasoningContent.isEmpty
            || (message.isThinkingEnabled && message.isStreaming && message.content.isEmpty)
    }

    private var rendersMarkdown: Bool {
        message.role == .assistant
    }

    private var foregroundStyle: Color {
        message.role == .user ? .white : Color(nsColor: .labelColor)
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user:
            return .accentColor
        case .assistant:
            return .clear
        case .error:
            return Color(nsColor: .systemRed).opacity(0.12)
        }
    }

    private var borderColor: Color {
        switch message.role {
        case .user:
            return .clear
        case .assistant:
            return .clear
        case .error:
            return Color(nsColor: .systemRed).opacity(0.45)
        }
    }

    private var responseMetrics: ChatResponseMetrics? {
        guard message.role == .assistant,
              !message.isStreaming,
              let responseMetrics = message.responseMetrics,
              responseMetrics.hasVisibleValues
        else {
            return nil
        }

        return responseMetrics
    }

    private var showsCopyAction: Bool {
        message.role == .assistant
            && !message.isStreaming
            && !message.content.isEmpty
    }

    private func copyResponse() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.content, forType: .string)

        withAnimation(.easeInOut(duration: 0.15)) {
            didCopyResponse = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeInOut(duration: 0.15)) {
                didCopyResponse = false
            }
        }
    }
}

private struct ChatCopyResponseButton: View {
    let didCopy: Bool
    let onCopy: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onCopy) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.medium))
                .foregroundStyle(
                    didCopy
                        ? Color.green
                        : (isHovering ? Color.primary : Color.secondary)
                )
                .frame(width: 30, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(didCopy ? "Copied" : "Copy response")
        .accessibilityLabel(didCopy ? "Response copied" : "Copy response")
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.15), value: didCopy)
    }
}

private struct ChatThinkingBubble: View {
    let content: String
    let isThinking: Bool
    let thinkingDuration: TimeInterval?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if isThinking {
                        ChatThinkingShimmerText("Working")
                    } else {
                        Text(completedTitle)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Show less reasoning" : "Show full reasoning")

            if isExpanded || isThinking {
                Divider()

                Group {
                    if isExpanded {
                        ChatMessageText(
                            content: content,
                            rendersMarkdown: !isThinking,
                            isStreaming: isThinking
                        )
                        .font(.callout)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                    } else {
                        Text(content)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(height: 58, alignment: .bottomLeading)
                            .clipped()
                            .padding(12)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.075), lineWidth: 0.75)
        }
        .animation(.easeInOut(duration: 0.2), value: isThinking)
        .accessibilityElement(children: .contain)
    }

    private var completedTitle: String {
        guard let thinkingDuration else {
            return "Worked"
        }
        return "Worked for \(NativFormatting.elapsedDuration(thinkingDuration))"
    }
}

private struct ChatThinkingShimmerText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Group {
            if reduceMotion {
                label
                    .foregroundStyle(.secondary)
            } else {
                TimelineView(.animation) { context in
                    let duration = 1.65
                    let progress = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: duration) / duration

                    label
                        .foregroundStyle(Color.primary.opacity(0.38))
                        .overlay {
                            GeometryReader { proxy in
                                let beamWidth = max(34, proxy.size.width * 0.55)

                                LinearGradient(
                                    colors: [
                                        .clear,
                                        Color.secondary.opacity(0.25),
                                        Color.primary.opacity(0.75),
                                        .white,
                                        Color.primary.opacity(0.75),
                                        Color.secondary.opacity(0.25),
                                        .clear
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: beamWidth)
                                .offset(
                                    x: -beamWidth
                                        + (proxy.size.width + beamWidth) * progress
                                )
                                .blur(radius: 1.1)
                            }
                            .mask(label)
                            .allowsHitTesting(false)
                        }
                }
            }
        }
        .fixedSize()
        .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(.callout.weight(.medium))
    }
}

private struct ChatResponseMetricsRow: View {
    let metrics: ChatResponseMetrics

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                metricPills
            }

            VStack(alignment: .leading, spacing: 6) {
                metricPills
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var metricPills: some View {
        ChatResponseMetricPill(
            label: "Total tokens",
            value: NativFormatting.integer(metrics.totalTokens)
        )
        ChatResponseMetricPill(
            label: "Decode tok/s",
            value: NativFormatting.rate(metrics.decodeTokensPerSecond)
        )
        ChatResponseMetricPill(
            label: "Peak memory",
            value: metrics.peakMemoryGB.map(NativFormatting.gigabytes) ?? "--"
        )
    }
}

private struct ChatResponseMetricPill: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)

            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .help("\(label): \(value)")
    }
}

private struct ChatImageAttachmentStack: View {
    let attachments: [ChatImageAttachment]
    let isUserMessage: Bool

    var body: some View {
        VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                ChatImageAttachmentView(attachment: attachment)
            }
        }
    }
}

private struct ChatImageAttachmentView: View {
    let attachment: ChatImageAttachment

    private let maximumSideLength: CGFloat = 300

    var body: some View {
        Group {
            if let image {
                let size = displaySize(for: image)

                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.title2)
                    Text(attachment.filename)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(width: 180, height: 120)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .help(attachment.filename)
        .accessibilityLabel(attachment.filename)
    }

    private var image: NSImage? {
        guard let data = attachment.imageData else {
            return nil
        }
        return NSImage(data: data)
    }

    private func displaySize(for image: NSImage) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: maximumSideLength, height: maximumSideLength)
        }

        let scale = min(1, maximumSideLength / max(image.size.width, image.size.height))
        return CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
    }
}

private struct ChatMessageText: View {
    let content: String
    let rendersMarkdown: Bool
    let isStreaming: Bool

    @ViewBuilder
    var body: some View {
        if rendersMarkdown && !isStreaming {
            StructuredText(
                markdown: NativMarkdownFormatting.normalizedMathDelimiters(in: content),
                syntaxExtensions: [.math]
            )
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
            .font(.body)
        } else {
            renderedText
                .textSelection(.enabled)
                .font(.body)
        }
    }

    private var renderedText: Text {
        guard rendersMarkdown,
              let attributed = try? AttributedString(
                markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
              )
        else {
            return Text(content)
        }

        return Text(attributed)
    }
}

private struct ChatEmptyTranscriptView: View {
    let isRunning: Bool
    let selectedModelID: String?

    var body: some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        if !isRunning {
            return "Server is stopped"
        }
        if selectedModelID == nil {
            return "No model selected"
        }
        return "No messages"
    }

    private var detail: String {
        if !isRunning {
            return "Start the server to chat."
        }
        if selectedModelID == nil {
            return "Choose a model in Models."
        }
        return selectedModelID ?? ""
    }
}

#Preview {
    ChatView(model: .init(), chat: ChatViewModel(), showsConfiguration: true)
}
