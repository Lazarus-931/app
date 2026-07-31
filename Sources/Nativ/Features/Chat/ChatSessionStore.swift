import Foundation
import NativServerKit
import UniformTypeIdentifiers

struct ChatSession: Identifiable, Equatable, Codable {
    var id: UUID
    var title: String
    var customTitle: String?
    var lastInferenceDevice: String?
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatTranscriptMessage]
    var pinned: Bool?
    var pinnedOrder: Int?
    var sessionOrder: Int?

    var summary: ChatSessionSummary {
        ChatSessionSummary(
            id: id,
            title: displayTitle,
            lastInferenceDevice: lastInferenceDevice,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageCount: messages.count,
            isPinned: pinned ?? false,
            pinnedOrder: pinnedOrder,
            sessionOrder: sessionOrder
        )
    }

    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty {
            return customTitle
        }
        return Self.defaultTitle(for: messages, createdAt: createdAt, fallback: title)
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
    let lastInferenceDevice: String?
    let createdAt: Date
    let updatedAt: Date
    let messageCount: Int
    let isPinned: Bool
    let pinnedOrder: Int?
    let sessionOrder: Int?

    static func recencySort(_ lhs: ChatSessionSummary, _ rhs: ChatSessionSummary) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.updatedAt > rhs.updatedAt
    }
}

struct ChatFolderAttachment: Identifiable, Equatable, Codable {
    let id: UUID
    var folderName: String
    var includedFileCount: Int
    var totalFileCount: Int
    var approxTokens: Int
    var text: String

    init(
        id: UUID = UUID(),
        folderName: String,
        includedFileCount: Int,
        totalFileCount: Int,
        approxTokens: Int,
        text: String
    ) {
        self.id = id
        self.folderName = folderName
        self.includedFileCount = includedFileCount
        self.totalFileCount = totalFileCount
        self.approxTokens = approxTokens
        self.text = text
    }
}

struct ChatTranscriptMessage: Identifiable, Equatable, Codable {
    enum Role: String, Equatable, Codable {
        case user
        case assistant
        case tool
        case error
    }

    enum ToolStatus: String, Equatable, Codable {
        case running
        case succeeded
        case failed
        case cancelled
        case awaitingConsent
        case declined
    }

    let id: UUID
    var role: Role
    var content: String
    var reasoningContent: String
    var modelID: String?
    var createdAt: Date
    var isStreaming: Bool
    var isThinkingEnabled: Bool
    var thinkingDuration: TimeInterval?
    var imageAttachments: [ChatImageAttachment]
    var folderAttachments: [ChatFolderAttachment]
    var responseMetrics: ChatResponseMetrics?
    var generatedImages: [ChatImageAttachment]
    var imageGenerationMetrics: ImageGenerationMetrics?
    var toolCalls: [MLXChatToolCall]
    var toolCallID: String?
    var toolName: String?
    var toolStatus: ToolStatus?
    var toolArguments: String?

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        reasoningContent: String = "",
        modelID: String? = nil,
        createdAt: Date = Date(),
        isStreaming: Bool = false,
        isThinkingEnabled: Bool = false,
        thinkingDuration: TimeInterval? = nil,
        imageAttachments: [ChatImageAttachment] = [],
        folderAttachments: [ChatFolderAttachment] = [],
        responseMetrics: ChatResponseMetrics? = nil,
        generatedImages: [ChatImageAttachment] = [],
        imageGenerationMetrics: ImageGenerationMetrics? = nil,
        toolCalls: [MLXChatToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil,
        toolStatus: ToolStatus? = nil,
        toolArguments: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.modelID = modelID
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.isThinkingEnabled = isThinkingEnabled
        self.thinkingDuration = thinkingDuration
        self.imageAttachments = imageAttachments
        self.folderAttachments = folderAttachments
        self.responseMetrics = responseMetrics
        self.generatedImages = generatedImages
        self.imageGenerationMetrics = imageGenerationMetrics
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.toolStatus = toolStatus
        self.toolArguments = toolArguments
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case reasoningContent
        case modelID
        case createdAt
        case isStreaming
        case isThinkingEnabled
        case thinkingDuration
        case imageAttachments
        case folderAttachments
        case responseMetrics
        case generatedImages
        case imageGenerationMetrics
        case toolCalls
        case toolCallID
        case toolName
        case toolStatus
        case toolArguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent) ?? ""
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        isStreaming = false
        isThinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .isThinkingEnabled) ?? false
        thinkingDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .thinkingDuration)
        imageAttachments = try container.decodeIfPresent([ChatImageAttachment].self, forKey: .imageAttachments) ?? []
        folderAttachments = try container.decodeIfPresent([ChatFolderAttachment].self, forKey: .folderAttachments) ?? []
        responseMetrics = try container.decodeIfPresent(ChatResponseMetrics.self, forKey: .responseMetrics)
        generatedImages = try container.decodeIfPresent([ChatImageAttachment].self, forKey: .generatedImages) ?? []
        imageGenerationMetrics = try container.decodeIfPresent(ImageGenerationMetrics.self, forKey: .imageGenerationMetrics)
        toolCalls = try container.decodeIfPresent([MLXChatToolCall].self, forKey: .toolCalls) ?? []
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        toolStatus = try container.decodeIfPresent(ToolStatus.self, forKey: .toolStatus)
        toolArguments = try container.decodeIfPresent(String.self, forKey: .toolArguments)

        if role == .error,
           content == NativChatError.missingAssistantContent.localizedDescription,
           !reasoningContent.isEmpty {
            role = .assistant
            content = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(modelID, forKey: .modelID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(false, forKey: .isStreaming)
        try container.encode(isThinkingEnabled, forKey: .isThinkingEnabled)
        try container.encodeIfPresent(thinkingDuration, forKey: .thinkingDuration)
        try container.encode(imageAttachments, forKey: .imageAttachments)
        try container.encode(folderAttachments, forKey: .folderAttachments)
        try container.encodeIfPresent(responseMetrics, forKey: .responseMetrics)
        try container.encode(generatedImages, forKey: .generatedImages)
        try container.encodeIfPresent(imageGenerationMetrics, forKey: .imageGenerationMetrics)
        try container.encode(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        try container.encodeIfPresent(toolStatus, forKey: .toolStatus)
        try container.encodeIfPresent(toolArguments, forKey: .toolArguments)
    }

    var apiMessage: MLXChatMessage? {
        switch role {
        case .user:
            let folderText = folderAttachments.map(\.text).joined(separator: "\n\n")
            let combined = [folderText, content].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let imageParts = imageAttachments.filter {
                ArtifactKind.resolve(mimeType: $0.mimeType, filename: $0.filename) == .image
            }
            if !imageParts.isEmpty {
                var parts: [MLXChatContentPart] = []
                if !combined.isEmpty {
                    parts.append(MLXChatContentPart(text: combined))
                }
                parts.append(contentsOf: imageParts.map { MLXChatContentPart(imageURL: $0.dataURL) })
                return MLXChatMessage(role: "user", content: .parts(parts))
            }

            return MLXChatMessage(role: "user", content: combined)
        case .assistant:
            guard !content.isEmpty || !reasoningContent.isEmpty || !toolCalls.isEmpty else {
                return nil
            }
            return MLXChatMessage(
                role: "assistant",
                content: content,
                reasoningContent: reasoningContent.isEmpty ? nil : reasoningContent,
                toolCalls: toolCalls.isEmpty ? nil : toolCalls
            )
        case .tool:
            guard let toolCallID else {
                return nil
            }
            return MLXChatMessage(
                role: "tool",
                content: content,
                toolCallID: toolCallID,
                name: toolName
            )
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

struct ChatSessionStore {
    private let fileManager = FileManager.default

    init() {}

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
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Chat", isDirectory: true)
    }

    private var sessionsDirectory: URL {
        chatDirectory.appendingPathComponent("Sessions", isDirectory: true)
    }

    private var legacyTranscriptURL: URL {
        chatDirectory.appendingPathComponent("current.json")
    }
}
