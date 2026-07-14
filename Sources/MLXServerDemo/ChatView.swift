import AppKit
import Foundation
import MLXServerKit
import SwiftUI
import Textual
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject var model: MLXServerDemoModel
    @ObservedObject var chat: ChatViewModel
    @State private var transcriptScrollPosition = ScrollPosition(edge: .bottom)
    @State private var composerHeight: CGFloat = 0

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

            Divider()

            ChatConfigurationSidebar(
                settings: $model.settings,
                settingsRequireRestart: model.settingsRequireRestart,
                onReset: model.resetSettings
            )
            .frame(width: 320)
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
            LazyVStack(alignment: .leading, spacing: 12) {
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
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, max(18, composerHeight))
        }
        .scrollPosition($transcriptScrollPosition)
        .onChange(of: chat.scrollToken) { _, _ in
            transcriptScrollPosition.scrollTo(edge: .bottom)
        }
        .onAppear {
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
    @Published private(set) var scrollToken = 0

    private let client = MLXServerChatClient()
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
            return "Response in progress."
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

    func send(using appModel: MLXServerDemoModel) {
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
            isStreaming: true
        ))
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
            thinkingBudget: settings.thinkingEnabled ? settings.thinkingBudget : nil,
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
                let completion = try await client.streamChat(request) { [weak self] delta in
                    await MainActor.run {
                        self?.append(delta: delta, to: assistantID)
                    }
                }
                finishAssistantMessage(
                    assistantID,
                    fallbackContent: completion.content,
                    responseMetrics: ChatResponseMetrics(completion: completion),
                    isCancelled: false
                )
                appModel?.refreshMetricsIfRunning(force: true)
            } catch is CancellationError {
                finishAssistantMessage(
                    assistantID,
                    fallbackContent: "Response cancelled.",
                    responseMetrics: nil,
                    isCancelled: true
                )
            } catch {
                failAssistantMessage(assistantID, error: error)
                appModel?.refreshMetricsIfRunning(force: true)
            }

            isSending = false
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
        draft = ""
        pendingImageAttachments.removeAll()
        messages.removeAll()
        persistCurrentSession(updateTimestamp: true)
        bumpScroll()
    }

    private func append(delta: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[index].content.append(delta)
        bumpScroll()
    }

    private func finishAssistantMessage(
        _ id: UUID,
        fallbackContent: String,
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
        if isCancelled && messages[index].content == fallbackContent {
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

private struct ChatSession: Identifiable, Equatable, Codable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatTranscriptMessage]

    var summary: ChatSessionSummary {
        ChatSessionSummary(
            id: id,
            title: displayTitle,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageCount: messages.count
        )
    }

    var displayTitle: String {
        Self.defaultTitle(for: messages, createdAt: createdAt, fallback: title)
    }

    static func recencySort(_ lhs: ChatSession, _ rhs: ChatSession) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    static func timestampTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func defaultTitle(
        for messages: [ChatTranscriptMessage],
        createdAt: Date,
        fallback: String? = nil
    ) -> String {
        if let firstUserMessage = messages.first(where: { $0.role == .user }) {
            if let firstUserTitle = title(fromUserContent: firstUserMessage.content) {
                return firstUserTitle
            }

            if !firstUserMessage.imageAttachments.isEmpty {
                if firstUserMessage.imageAttachments.count == 1 {
                    return firstUserMessage.imageAttachments[0].filename
                }
                return "\(firstUserMessage.imageAttachments.count) images"
            }
        }

        let trimmedFallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedFallback.isEmpty {
            return trimmedFallback
        }

        return timestampTitle(for: createdAt)
    }

    private static func title(fromUserContent content: String) -> String? {
        let firstLine = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        guard let firstLine else {
            return nil
        }

        return truncateTitle(firstLine)
    }

    private static func truncateTitle(_ value: String, maxLength: Int = 56) -> String {
        guard value.count > maxLength else {
            return value
        }

        let keep = max(1, maxLength - 3)
        return "\(value.prefix(keep))..."
    }
}

struct ChatSessionSummary: Identifiable, Equatable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let messageCount: Int

    static func recencySort(_ lhs: ChatSessionSummary, _ rhs: ChatSessionSummary) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.updatedAt > rhs.updatedAt
    }
}

struct ChatTranscriptMessage: Identifiable, Equatable, Codable {
    enum Role: String, Equatable, Codable {
        case user
        case assistant
        case error
    }

    let id: UUID
    var role: Role
    var content: String
    var modelID: String?
    var createdAt: Date
    var isStreaming: Bool
    var imageAttachments: [ChatImageAttachment]
    var responseMetrics: ChatResponseMetrics?

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        modelID: String? = nil,
        createdAt: Date = Date(),
        isStreaming: Bool = false,
        imageAttachments: [ChatImageAttachment] = [],
        responseMetrics: ChatResponseMetrics? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.modelID = modelID
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.imageAttachments = imageAttachments
        self.responseMetrics = responseMetrics
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case modelID
        case createdAt
        case isStreaming
        case imageAttachments
        case responseMetrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        isStreaming = false
        imageAttachments = try container.decodeIfPresent([ChatImageAttachment].self, forKey: .imageAttachments) ?? []
        responseMetrics = try container.decodeIfPresent(ChatResponseMetrics.self, forKey: .responseMetrics)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(modelID, forKey: .modelID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(false, forKey: .isStreaming)
        try container.encode(imageAttachments, forKey: .imageAttachments)
        try container.encodeIfPresent(responseMetrics, forKey: .responseMetrics)
    }

    var apiMessage: MLXChatMessage? {
        switch role {
        case .user:
            if !imageAttachments.isEmpty {
                var parts: [MLXChatContentPart] = []
                if !content.isEmpty {
                    parts.append(MLXChatContentPart(text: content))
                }
                parts.append(contentsOf: imageAttachments.map { MLXChatContentPart(imageURL: $0.dataURL) })
                return MLXChatMessage(role: "user", content: .parts(parts))
            }

            return MLXChatMessage(role: "user", content: content)
        case .assistant:
            guard !content.isEmpty else {
                return nil
            }
            return MLXChatMessage(role: "assistant", content: content)
        case .error:
            return nil
        }
    }
}

struct ChatResponseMetrics: Equatable, Codable {
    let totalTokens: Int?
    let decodeTokensPerSecond: Double?
    let peakMemoryGB: Double?

    var hasVisibleValues: Bool {
        totalTokens != nil || decodeTokensPerSecond != nil || peakMemoryGB != nil
    }

    init(
        totalTokens: Int? = nil,
        decodeTokensPerSecond: Double? = nil,
        peakMemoryGB: Double? = nil
    ) {
        self.totalTokens = totalTokens
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.peakMemoryGB = peakMemoryGB
    }

    init(completion: MLXChatCompletion) {
        self.init(
            totalTokens: completion.usage?.resolvedTotalTokens,
            decodeTokensPerSecond: completion.resolvedDecodeTokensPerSecond,
            peakMemoryGB: completion.usage?.peakMemoryGB
        )
    }
}

struct ChatImageAttachment: Identifiable, Equatable, Codable {
    let id: UUID
    var filename: String
    var mimeType: String
    var base64Data: String

    init(id: UUID = UUID(), filename: String, mimeType: String, base64Data: String) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.base64Data = base64Data
    }

    init(contentsOf url: URL) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let type = UTType(filenameExtension: url.pathExtension)
        self.init(
            filename: url.lastPathComponent,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            base64Data: data.base64EncodedString()
        )
    }

    var dataURL: String {
        "data:\(mimeType);base64,\(base64Data)"
    }

    var imageData: Data? {
        Data(base64Encoded: base64Data)
    }
}

private struct ChatSessionStore {
    private let fileManager = FileManager.default

    func loadSessions() -> [ChatSession] {
        migrateLegacyTranscriptIfNeeded()

        guard let urls = try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap(loadSession)
            .sorted(by: ChatSession.recencySort)
    }

    func loadSession(id: UUID) -> ChatSession? {
        loadSession(from: sessionURL(for: id))
    }

    func saveSession(_ session: ChatSession) {
        do {
            try fileManager.createDirectory(
                at: sessionsDirectory,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(session)
            try data.write(to: sessionURL(for: session.id), options: .atomic)
        } catch {
            // Chat persistence should not block the local server UI.
        }
    }

    func deleteSession(id: UUID) {
        try? fileManager.removeItem(at: sessionURL(for: id))
    }

    private func loadSession(from url: URL) -> ChatSession? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ChatSession.self, from: data)
        } catch {
            return nil
        }
    }

    private func migrateLegacyTranscriptIfNeeded() {
        guard existingSessionURLs().isEmpty,
              let data = try? Data(contentsOf: legacyTranscriptURL)
        else {
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let messages = try decoder.decode([ChatTranscriptMessage].self, from: data)
            guard !messages.isEmpty else {
                try? fileManager.removeItem(at: legacyTranscriptURL)
                return
            }

            let createdAt = messages.first?.createdAt ?? Date()
            let updatedAt = messages.last?.createdAt ?? createdAt
            let session = ChatSession(
                id: UUID(),
                title: ChatSession.timestampTitle(for: createdAt),
                createdAt: createdAt,
                updatedAt: updatedAt,
                messages: messages
            )
            saveSession(session)
            try? fileManager.removeItem(at: legacyTranscriptURL)
        } catch {
            return
        }
    }

    private func existingSessionURLs() -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        )) ?? [])
        .filter { $0.pathExtension == "json" }
    }

    private func sessionURL(for id: UUID) -> URL {
        sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private var chatDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return caches
            .appendingPathComponent("MLXServerDemo", isDirectory: true)
            .appendingPathComponent("Chat", isDirectory: true)
    }

    private var sessionsDirectory: URL {
        chatDirectory.appendingPathComponent("Sessions", isDirectory: true)
    }

    private var legacyTranscriptURL: URL {
        chatDirectory.appendingPathComponent("current.json")
    }
}

private struct ChatSessionsSidebar: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Chats")
                    .font(.headline)

                Spacer(minLength: 0)

                Button {
                    viewModel.createSession()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isSending)
                .help("New chat")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(viewModel.sessions) { session in
                        ChatSessionRow(
                            session: session,
                            isSelected: session.id == viewModel.currentSessionID,
                            isCurrent: session.id == viewModel.currentSessionID,
                            isDisabled: viewModel.isSending
                        ) {
                            viewModel.selectSession(session.id)
                        } onDelete: {
                            viewModel.deleteSession(session.id)
                        }
                    }
                }
                .padding(8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct ChatSessionRow: View {
    let session: ChatSessionSummary
    let isSelected: Bool
    let isCurrent: Bool
    let isDisabled: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
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
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled && !isCurrent ? 0.55 : 1)
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

private struct ChatConfigurationSidebar: View {
    @Binding var settings: MLXServerSettings
    let settingsRequireRestart: Bool
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    modelContextSection
                    kvQuantizationSection
                    thinkingSection
                    samplingSection
                    speculativeDecodingSection
                    structuredOutputSection
                    prefixCachingSection
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Model Configuration", systemImage: "slider.horizontal.3")
                    .font(.headline)

                Spacer(minLength: 0)

                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset model configuration")
            }

            if settingsRequireRestart {
                Label("Server restart required", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Request settings apply to the next message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var modelContextSection: some View {
        ChatConfigurationSection(title: "Model Context", systemImage: "text.append") {
            ConfigurationIntegerField(
                title: "Max output",
                value: $settings.maxTokens,
                range: 1...262_144
            )

            ConfigurationIntegerField(
                title: "Context window",
                value: $settings.maxKVSize,
                range: 0...1_048_576
            )

            Text("0 uses the model's native context window.")
                .configurationHintStyle()

            VStack(alignment: .leading, spacing: 6) {
                Text("System prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $settings.systemPrompt)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 76)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    }
            }
        }
    }

    private var kvQuantizationSection: some View {
        ChatConfigurationSection(title: "KV Quantization", systemImage: "memorychip") {
            Toggle("Quantize KV cache", isOn: $settings.kvQuantizationEnabled)
                .configurationToggleStyle()

            if settings.kvQuantizationEnabled {
                Toggle("TurboQuant", isOn: turboQuantBinding)
                    .configurationToggleStyle()

                ConfigurationDoubleField(
                    title: "KV bits",
                    value: $settings.kvBits,
                    range: 2...16
                )

                if !settings.turboQuantEnabled {
                    ConfigurationIntegerField(
                        title: "Group size",
                        value: $settings.kvGroupSize,
                        range: 1...1024
                    )
                }

                ConfigurationIntegerField(
                    title: "Quantize after",
                    value: $settings.quantizedKVStart,
                    range: 0...1_048_576
                )

                Text("Changes to the KV cache require a server restart.")
                    .configurationHintStyle()
            }
        }
    }

    private var thinkingSection: some View {
        ChatConfigurationSection(title: "Thinking", systemImage: "brain.head.profile") {
            Toggle("Enable Thinking", isOn: $settings.thinkingEnabled)
                .configurationToggleStyle()

            if settings.thinkingEnabled {
                ConfigurationIntegerField(
                    title: "Budget",
                    value: $settings.thinkingBudget,
                    range: 1...262_144
                )
                ConfigurationTextField(title: "Start token", text: $settings.thinkingStartToken)
                ConfigurationTextField(title: "EOS token", text: $settings.thinkingEndToken)
            }
        }
    }

    private var samplingSection: some View {
        ChatConfigurationSection(title: "Sampling", systemImage: "dial.medium") {
            ConfigurationDoubleField(
                title: "Temperature",
                value: $settings.temperature,
                range: 0...2
            )
            ConfigurationIntegerField(
                title: "Top K",
                value: $settings.topK,
                range: 0...10_000
            )
            ConfigurationDoubleField(
                title: "Top P",
                value: $settings.topP,
                range: 0...1
            )
            ConfigurationDoubleField(
                title: "Min P",
                value: $settings.minP,
                range: 0...1
            )

            Toggle("Repetition penalty", isOn: $settings.repetitionPenaltyEnabled)
                .configurationToggleStyle()

            if settings.repetitionPenaltyEnabled {
                ConfigurationDoubleField(
                    title: "Penalty",
                    value: $settings.repetitionPenalty,
                    range: 0...4
                )
            }
        }
    }

    private var speculativeDecodingSection: some View {
        ChatConfigurationSection(title: "Speculative Decoding", systemImage: "hare") {
            Toggle("Enable drafter", isOn: speculativeDecodingBinding)
                .configurationToggleStyle()

            if settings.speculativeDecodingEnabled {
                ConfigurationTextField(title: "Draft model", text: $settings.draftModelID)

                HStack(spacing: 8) {
                    Text("Family")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Picker("", selection: $settings.draftKind) {
                        Text("Auto").tag("auto")
                        Text("DFlash").tag("dflash")
                        Text("EAGLE3").tag("eagle3")
                        Text("MTP").tag("mtp")
                    }
                    .labelsHidden()
                    .frame(width: 112)
                }
                .font(.caption)

                ConfigurationIntegerField(
                    title: "Block size",
                    value: $settings.draftBlockSize,
                    range: 0...1024
                )

                Text(settings.draftModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Enter a drafter model to activate speculative decoding."
                    : "The drafter is loaded after the next server restart.")
                    .configurationHintStyle(
                        isError: settings.draftModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
    }

    private var structuredOutputSection: some View {
        ChatConfigurationSection(title: "Structured Output", systemImage: "curlybraces") {
            Toggle("Enforce JSON schema", isOn: structuredOutputBinding)
                .configurationToggleStyle()

            if settings.structuredOutputEnabled {
                ConfigurationTextField(title: "Schema name", text: $settings.structuredOutputName)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("JSON schema")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        Button("Reset") {
                            settings.structuredOutputSchema = MLXServerSettings.defaultStructuredOutputSchema
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }

                    TextEditor(text: $settings.structuredOutputSchema)
                        .font(.system(.caption, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 128)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(
                                    settings.structuredOutputValidationError == nil
                                        ? Color(nsColor: .separatorColor)
                                        : Color.red.opacity(0.7),
                                    lineWidth: 0.5
                                )
                        }
                }

                if let error = settings.structuredOutputValidationError {
                    Text(error)
                        .configurationHintStyle(isError: true)
                }
            }
        }
    }

    private var prefixCachingSection: some View {
        ChatConfigurationSection(title: "Prefix Caching", systemImage: "bolt.horizontal.circle") {
            Toggle("Enable automatic caching", isOn: $settings.prefixCachingEnabled)
                .configurationToggleStyle()

            if settings.prefixCachingEnabled {
                ConfigurationIntegerField(
                    title: "Cache blocks",
                    value: $settings.prefixCacheBlocks,
                    range: 1...1_048_576
                )
                ConfigurationIntegerField(
                    title: "Tokens per block",
                    value: $settings.prefixCacheBlockSize,
                    range: 1...4096
                )
                Text("Shared prompt prefixes are reused after a server restart.")
                    .configurationHintStyle()
            }
        }
    }

    private var turboQuantBinding: Binding<Bool> {
        Binding(
            get: { settings.turboQuantEnabled },
            set: { enabled in
                settings.turboQuantEnabled = enabled
                if enabled, settings.kvBits == 8 {
                    settings.kvBits = 3.5
                } else if !enabled, settings.kvBits == 3.5 {
                    settings.kvBits = 8
                }
            }
        )
    }

    private var speculativeDecodingBinding: Binding<Bool> {
        Binding(
            get: { settings.speculativeDecodingEnabled },
            set: { enabled in
                settings.speculativeDecodingEnabled = enabled
                if enabled {
                    settings.structuredOutputEnabled = false
                }
            }
        )
    }

    private var structuredOutputBinding: Binding<Bool> {
        Binding(
            get: { settings.structuredOutputEnabled },
            set: { enabled in
                settings.structuredOutputEnabled = enabled
                if enabled {
                    settings.speculativeDecodingEnabled = false
                }
            }
        )
    }
}

private struct ChatConfigurationSection<Content: View>: View {
    let title: String
    let systemImage: String
    private let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
        }
    }
}

private struct ConfigurationIntegerField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            TextField("", value: $value, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 88)
                .onChange(of: value) { _, newValue in
                    value = min(max(newValue, range.lowerBound), range.upperBound)
                }
        }
        .font(.caption)
    }
}

private struct ConfigurationDoubleField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            TextField(
                "",
                value: $value,
                format: .number.precision(.fractionLength(0...3))
            )
            .multilineTextAlignment(.trailing)
            .frame(width: 88)
            .onChange(of: value) { _, newValue in
                value = min(max(newValue, range.lowerBound), range.upperBound)
            }
        }
        .font(.caption)
    }
}

private struct ConfigurationTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: $text)
                .font(.caption)
        }
    }
}

private extension View {
    func configurationToggleStyle() -> some View {
        toggleStyle(.switch)
            .controlSize(.small)
            .font(.caption)
    }

    func configurationHintStyle(isError: Bool = false) -> some View {
        font(.caption2)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        MLXServerDemoFormatting.truncateModelName(value, maxLength: 34)
    }
}

private struct ChatMessageRow: View {
    let message: ChatTranscriptMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if message.role == .user {
                Spacer(minLength: 80)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .bottom, spacing: 8) {
                    if message.isStreaming && message.content.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                    }

                    VStack(alignment: contentStackAlignment, spacing: 6) {
                        if !message.imageAttachments.isEmpty {
                            ChatImageAttachmentStack(
                                attachments: message.imageAttachments,
                                isUserMessage: message.role == .user
                            )
                        }

                        if showsTextContent {
                            textBubble
                        }
                    }

                    if message.isStreaming && !message.content.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let responseMetrics {
                    ChatResponseMetricsRow(metrics: responseMetrics)
                }
            }

            if message.role != .user {
                Spacer(minLength: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: rowAlignment)
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
                .frame(maxWidth: 560, alignment: alignment)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
            return "You"
        case .assistant:
            return message.modelID.map { MLXServerDemoFormatting.truncateModelName($0, maxLength: 42) } ?? "Assistant"
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
        !message.content.isEmpty || message.imageAttachments.isEmpty || message.isStreaming
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
            return Color(nsColor: .controlBackgroundColor)
        case .error:
            return Color(nsColor: .systemRed).opacity(0.12)
        }
    }

    private var borderColor: Color {
        switch message.role {
        case .user:
            return .clear
        case .assistant:
            return Color(nsColor: .separatorColor)
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
            value: MLXServerDemoFormatting.integer(metrics.totalTokens)
        )
        ChatResponseMetricPill(
            label: "Decode tok/s",
            value: MLXServerDemoFormatting.rate(metrics.decodeTokensPerSecond)
        )
        ChatResponseMetricPill(
            label: "Peak memory",
            value: metrics.peakMemoryGB.map(MLXServerDemoFormatting.gigabytes) ?? "--"
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

private struct ChatImageThumbnail: View {
    let attachment: ChatImageAttachment
    let isUserMessage: Bool
    var width: CGFloat = 120
    var height: CGFloat = 90

    var body: some View {
        Group {
            if let data = attachment.imageData,
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.title3)
                    Text(attachment.filename)
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(isUserMessage ? Color.white.opacity(0.82) : Color(nsColor: .secondaryLabelColor))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isUserMessage ? Color.white.opacity(0.3) : Color(nsColor: .separatorColor),
                    lineWidth: 0.5
                )
        )
        .help(attachment.filename)
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
                markdown: MLXServerDemoMarkdownFormatting.normalizedMathDelimiters(in: content),
                syntaxExtensions: [.math]
            )
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
        } else {
            renderedText
                .textSelection(.enabled)
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

private struct ChatComposer: View {
    @ObservedObject var viewModel: ChatViewModel
    let unavailableReason: String?
    let canSend: Bool
    let onSend: () -> Void
    @State private var editorContentHeight: CGFloat = 0
    private let textInset = EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14)
    private let editorMinimumHeight: CGFloat = 64
    private let editorMaximumHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let unavailableReason {
                Text(unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ChatComposerTextEditor(
                        text: $viewModel.draft,
                        isEnabled: unavailableReason == nil,
                        onSubmit: onSend,
                        onContentHeightChange: { height in
                            editorContentHeight = height
                        }
                    )

                    if viewModel.draft.isEmpty {
                        Text("Message")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(textInset)
                            .offset(x: 4)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: editorHeight)

                if !viewModel.pendingImageAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.pendingImageAttachments) { attachment in
                                ChatPendingImageAttachmentView(attachment: attachment) {
                                    viewModel.removePendingImageAttachment(attachment.id)
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }

                HStack {
                    Menu {
                        Button {
                            viewModel.chooseImageAttachments()
                        } label: {
                            Label("Attach Image", systemImage: "photo.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .regular))
                            .frame(width: 30, height: 30)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(unavailableReason != nil)
                    .help("Add attachment")

                    Spacer(minLength: 12)

                    Button {
                        if viewModel.isSending {
                            viewModel.cancel()
                        } else {
                            onSend()
                        }
                    } label: {
                        Image(systemName: viewModel.isSending ? "stop.fill" : "arrow.up")
                            .font(.system(size: viewModel.isSending ? 10 : 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(actionButtonColor, in: Circle())
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.isSending && !canSend)
                    .help(viewModel.isSending ? "Stop response" : "Send (Return)")
                }
                .padding(.leading, 10)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
        }
        .padding(18)
    }

    private var actionButtonColor: Color {
        if viewModel.isSending || canSend {
            return .accentColor
        }
        return Color(nsColor: .tertiaryLabelColor)
    }

    private var editorHeight: CGFloat {
        min(max(editorContentHeight, editorMinimumHeight), editorMaximumHeight)
    }
}

private struct ChatComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let onSubmit: () -> Void
    let onContentHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onContentHeightChange: onContentHeightChange
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ChatComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = context.coordinator.handleSubmit
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        let scrollView = ChatComposerNSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.onLayout = context.coordinator.reportContentHeight

        context.coordinator.textView = textView
        context.coordinator.reportContentHeight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onContentHeightChange = onContentHeightChange

        guard let textView = context.coordinator.textView else {
            return
        }

        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled

        guard textView.string != text else {
            context.coordinator.reportContentHeight()
            return
        }

        textView.string = text
        context.coordinator.reportContentHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        var onSubmit: () -> Void
        var onContentHeightChange: (CGFloat) -> Void
        weak var textView: NSTextView?
        private var lastReportedHeight: CGFloat?

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onContentHeightChange: @escaping (CGFloat) -> Void
        ) {
            _text = text
            self.onSubmit = onSubmit
            self.onContentHeightChange = onContentHeightChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else {
                return
            }

            text = textView.string
            reportContentHeight()
        }

        func handleSubmit() {
            onSubmit()
        }

        func reportContentHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  textContainer.containerSize.width > 0
            else {
                return
            }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let measuredHeight = ceil(usedRect.maxY + (textView.textContainerInset.height * 2))

            guard lastReportedHeight.map({ abs($0 - measuredHeight) >= 0.5 }) ?? true else {
                return
            }

            lastReportedHeight = measuredHeight
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastReportedHeight == measuredHeight else {
                    return
                }
                self.onContentHeightChange(measuredHeight)
            }
        }
    }
}

private final class ChatComposerNSScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private final class ChatComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch ComposerReturnBehavior.resolve(for: event) {
        case .submit:
            onSubmit?()
        case .insertNewline:
            insertText("\n", replacementRange: selectedRange())
        case .passthrough:
            super.keyDown(with: event)
        }
    }
}

private enum ComposerReturnBehavior {
    case submit
    case insertNewline
    case passthrough

    static func resolve(for event: NSEvent) -> ComposerReturnBehavior {
        guard isReturnKey(event) else {
            return .passthrough
        }

        let modifiers = relevantModifiers(for: event)
        if modifiers == [.command] {
            return .insertNewline
        }
        if modifiers.isEmpty {
            return .submit
        }
        return .passthrough
    }

    private static func isReturnKey(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }

    private static func relevantModifiers(for event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection([.command, .control, .option, .shift])
    }
}

private struct ChatPendingImageAttachmentView: View {
    let attachment: ChatImageAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ChatImageThumbnail(
                attachment: attachment,
                isUserMessage: false,
                width: 42,
                height: 32
            )

            Text(attachment.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("Remove image")
        }
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
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
    ChatView(model: .init(), chat: ChatViewModel())
}
