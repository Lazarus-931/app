import AppKit
import Foundation
import MLXServerKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject var model: MLXServerDemoModel
    @ObservedObject var chat: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            ChatStatusBar(
                isRunning: model.isRunning,
                selectedModelID: selectedModelID,
                loadedModel: model.loadedModelDisplay,
                settingsRequireRestart: model.settingsRequireRestart,
                inFlight: model.metrics?.summary.inFlight
            )

            Divider()

            transcript

            Divider()

            ChatComposer(
                viewModel: chat,
                unavailableReason: unavailableReason,
                canSend: canSend,
                onSend: {
                    chat.send(using: model)
                }
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var selectedModelID: String? {
        model.settings.normalized().languageModelID
    }

    private var canSend: Bool {
        chat.canSend(isRunning: model.isRunning, selectedModelID: selectedModelID)
    }

    private var unavailableReason: String? {
        chat.unavailableReason(isRunning: model.isRunning, selectedModelID: selectedModelID)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
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

                    Color.clear
                        .frame(width: 1, height: 1)
                        .id(ChatViewModel.bottomAnchorID)
                }
                .padding(18)
            }
            .onChange(of: chat.scrollToken) { _, _ in
                proxy.scrollTo(ChatViewModel.bottomAnchorID, anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo(ChatViewModel.bottomAnchorID, anchor: .bottom)
            }
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    static let bottomAnchorID = "chat-bottom-anchor"

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
            return "Select a model in Settings."
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

        let createdAt = Date()
        let session = ChatSession(
            id: UUID(),
            title: ChatSession.timestampTitle(for: createdAt),
            createdAt: createdAt,
            updatedAt: createdAt,
            messages: []
        )

        storedSessions.append(session)
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
            storedSessions.append(session)
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

        let requestMessages = messages.compactMap(\.apiMessage)
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
                    isCancelled: false
                )
                appModel?.refreshMetricsIfRunning(force: true)
            } catch is CancellationError {
                finishAssistantMessage(
                    assistantID,
                    fallbackContent: "Response cancelled.",
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

    private func finishAssistantMessage(_ id: UUID, fallbackContent: String, isCancelled: Bool) {
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
        let summaries = storedSessions.map(\.summary)
        let sortedSessions = summaries.sorted(by: ChatSessionSummary.recencySort)

        guard let currentSessionID,
              let current = sortedSessions.first(where: { $0.id == currentSessionID })
        else {
            sessions = sortedSessions
            return
        }

        sessions = [current] + sortedSessions.filter { $0.id != currentSessionID }
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

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        modelID: String? = nil,
        createdAt: Date = Date(),
        isStreaming: Bool = false,
        imageAttachments: [ChatImageAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.modelID = modelID
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.imageAttachments = imageAttachments
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case modelID
        case createdAt
        case isStreaming
        case imageAttachments
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

private struct ChatStatusBar: View {
    let isRunning: Bool
    let selectedModelID: String?
    let loadedModel: String
    let settingsRequireRestart: Bool
    let inFlight: Int?

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

            if let inFlight {
                ChatStatusPill(label: "In flight", value: "\(inFlight)", systemImage: "arrow.triangle.2.circlepath")
            }

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

                    VStack(alignment: contentStackAlignment, spacing: 8) {
                        if !message.imageAttachments.isEmpty {
                            ChatImageAttachmentGrid(
                                attachments: message.imageAttachments,
                                isUserMessage: message.role == .user
                            )
                        }

                        if showsTextContent {
                            if usesCompactBubble {
                                ChatMessageText(
                                    content: displayContent,
                                    rendersMarkdown: rendersMarkdown
                                )
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: true, vertical: false)
                            } else {
                                ChatMessageText(
                                    content: displayContent,
                                    rendersMarkdown: rendersMarkdown
                                )
                                    .lineSpacing(2)
                                    .multilineTextAlignment(textAlignment)
                                    .frame(maxWidth: 560, alignment: alignment)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if message.isStreaming && !message.content.isEmpty {
                        ProgressView()
                            .controlSize(.small)
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

            if message.role != .user {
                Spacer(minLength: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: rowAlignment)
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
        message.imageAttachments.isEmpty
            && !displayContent.contains(where: \.isNewline)
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
}

private struct ChatImageAttachmentGrid: View {
    let attachments: [ChatImageAttachment]
    let isUserMessage: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 92, maximum: 132), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(attachments) { attachment in
                ChatImageThumbnail(attachment: attachment, isUserMessage: isUserMessage)
            }
        }
        .frame(maxWidth: min(CGFloat(max(attachments.count, 1)) * 140, 420), alignment: .leading)
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

    var body: some View {
        renderedText
            .textSelection(.enabled)
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
    private let textInset = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let unavailableReason {
                Text(unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

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
            }

            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )

                    ChatComposerTextEditor(
                        text: $viewModel.draft,
                        isEnabled: unavailableReason == nil,
                        onSubmit: onSend
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
                .frame(minHeight: 72, maxHeight: 120)

                Button {
                    viewModel.chooseImageAttachments()
                } label: {
                    Image(systemName: "photo.badge.plus")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .disabled(unavailableReason != nil)
                .help("Attach images")

                Button {
                    if viewModel.isSending {
                        viewModel.cancel()
                    }
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.isSending)
                .help("Stop response")

                Button {
                    onSend()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .help("Send (Return)")

                Button {
                    viewModel.clear()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.messages.isEmpty && viewModel.draft.isEmpty)
                .help("Clear conversation")
            }
        }
        .padding(18)
    }
}

private struct ChatComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
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

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onSubmit = onSubmit

        guard let textView = context.coordinator.textView else {
            return
        }

        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled

        guard textView.string != text else {
            return
        }

        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        var onSubmit: () -> Void
        weak var textView: NSTextView?

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            _text = text
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else {
                return
            }

            text = textView.string
        }

        func handleSubmit() {
            onSubmit()
        }
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
            return "Choose a model in Settings."
        }
        return selectedModelID ?? ""
    }
}

#Preview {
    ChatView(model: .init(), chat: ChatViewModel())
}
