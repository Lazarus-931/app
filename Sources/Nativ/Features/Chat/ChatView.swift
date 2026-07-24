import AppKit
import Foundation
import NativServerKit
import SwiftUI
import Textual
import UniformTypeIdentifiers

struct ChatQueuedPrompt: Identifiable, Equatable {
    let id: UUID
    let content: String
    let attachmentCount: Int
    let position: Int
}

enum ChatInferenceDevice: String, CaseIterable, Identifiable {
    case gpu
    case cpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gpu: "GPU"
        case .cpu: "CPU"
        }
    }
}

struct ChatView: View {
    private enum Layout {
        static let conversationMaxWidth: CGFloat = 680
        static let horizontalPadding: CGFloat = 32
    }

    @ObservedObject var model: NativModel
    @ObservedObject var chat: ChatViewModel
    @Binding var showsConfiguration: Bool
    var isFullScreen = false
    @State private var transcriptScrollPosition = ScrollPosition(edge: .bottom)
    @State private var composerHeight: CGFloat = 0
    @State private var followsLatestMessage = true
    @State private var isUserScrollingTranscript = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                transcript
                    .overlay(alignment: .bottom) {
                        ChatComposer(
                            model: model,
                            viewModel: chat,
                            unavailableReason: unavailableReason,
                            canCompose: canCompose,
                            canSend: canSend,
                            onSend: {
                                chat.send(using: model)
                            }
                        )
                        .frame(maxWidth: Layout.conversationMaxWidth)
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

        }
        .background(Color.nativWindow)
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                configurationButton

                if showsConfiguration {
                    configurationPopoverContent
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            }
                        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 12)
            .padding(.trailing, 22)
        }
    }

    private var configurationButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.28)) {
                showsConfiguration.toggle()
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .help(configurationVisibilityHelp)
        .accessibilityLabel(configurationVisibilityHelp)
    }

    private var configurationPopoverContent: some View {
        ChatConfigurationView(
            settings: $model.settings,
            settingsRequireRestart: model.settingsRequireRestart,
            onReset: model.resetSettings
        )
        .frame(width: 340, height: 540)
    }

    private var configurationVisibilityHelp: String {
        showsConfiguration ? "Hide model configuration" : "Model configuration"
    }

    private var chatTargetsCPU: Bool {
        model.cpuIsRunning && chat.targetDevice == .cpu
    }

    private var selectedModelID: String? {
        chatTargetsCPU ? model.cpuChatModelID : model.settings.normalized().languageModelID
    }

    private var chatTargetIsRunning: Bool {
        chatTargetsCPU ? model.cpuIsRunning : model.isRunning
    }

    private var canSend: Bool {
        model.settings.structuredOutputValidationError == nil
            && chat.canSend(isRunning: chatTargetIsRunning, selectedModelID: selectedModelID)
    }

    private var canCompose: Bool {
        chatTargetIsRunning
            && selectedModelID?.isEmpty == false
            && model.settings.structuredOutputValidationError == nil
    }

    private var unavailableReason: String? {
        chat.unavailableReason(isRunning: model.isRunning, selectedModelID: selectedModelID)
            ?? model.settings.structuredOutputValidationError
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if chat.visibleMessages.isEmpty {
                    if chat.messages.isEmpty {
                        ChatEmptyTranscriptView(
                            isRunning: model.isRunning,
                            selectedModelID: selectedModelID
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                    }
                } else {
                    ForEach(chat.visibleMessages) { message in
                        ChatMessageRow(message: message)
                            .id(message.id)
                    }
                }
            }
            .frame(maxWidth: Layout.conversationMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.top, 18)
            .padding(.bottom, max(18, composerHeight))
        }
        .scrollPosition($transcriptScrollPosition)
        .onScrollPhaseChange { _, newPhase, context in
            switch newPhase {
            case .tracking, .interacting:
                isUserScrollingTranscript = true
                followsLatestMessage = false
            case .decelerating:
                if isUserScrollingTranscript {
                    followsLatestMessage = false
                }
            case .idle:
                guard isUserScrollingTranscript else {
                    return
                }
                isUserScrollingTranscript = false
                followsLatestMessage = isAtTranscriptBottom(context.geometry)
            case .animating:
                break
            }
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

    private func isAtTranscriptBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.visibleRect.maxY >= geometry.contentSize.height - 8
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    private static let liveDecodeRateRefreshInterval: TimeInterval = 0.25
    private static let streamFlushInterval: TimeInterval = 1.0 / 30.0

    private struct QueuedChatRequest {
        let id: UUID
        let sessionID: UUID
        let userMessageID: UUID
        let assistantMessageID: UUID
        let settings: NativSettings
        let modelID: String
        let device: ChatInferenceDevice
        let baseURL: URL
        var isImageGeneration = false
        var imageWidth = 1024
        var imageHeight = 1024
        var referenceAttachment: ChatImageAttachment?
    }

    @Published private(set) var sessions: [ChatSessionSummary] = []
    @Published private(set) var currentSessionID: UUID?
    @Published private(set) var messages: [ChatTranscriptMessage] = []
    @Published private(set) var pendingImageAttachments: [ChatImageAttachment] = []
    @Published var draft = ""
    @Published private(set) var activeRequestSessionID: UUID?
    @Published private(set) var sendingStartedAt: Date?
    @Published private(set) var scrollToken = 0
    @Published var targetDevice: ChatInferenceDevice = .gpu
    @Published var activeModelIsImageGeneration = false
    @Published var imageGenerationWidth = 1024
    @Published var imageGenerationHeight = 1024

    private let sessionStore = ChatSessionStore()
    private var activeTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    @Published private var requestQueue: [QueuedChatRequest] = []
    private var storedSessions: [ChatSession] = []
    private var currentSession: ChatSession?
    private var liveDecodeRateRefreshDates: [UUID: Date] = [:]
    private var pendingStreamContent: [UUID: String] = [:]
    private var pendingStreamReasoning: [UUID: String] = [:]
    private var pendingStreamDecodeRate: [UUID: Double] = [:]
    private var streamFlushDates: [UUID: Date] = [:]
    private var streamFlushTasks: [UUID: Task<Void, Never>] = [:]
    private weak var appModel: NativModel?

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

    var isCurrentSessionSending: Bool {
        guard let activeRequestSessionID else {
            return false
        }
        return activeRequestSessionID == currentSessionID
    }

    var hasPendingRequests: Bool {
        activeRequestSessionID != nil || !requestQueue.isEmpty
    }

    var visibleMessages: [ChatTranscriptMessage] {
        let queuedMessageIDs = Set(
            requestQueue.lazy
                .filter { $0.sessionID == self.currentSessionID }
                .map(\.userMessageID)
        )
        return messages.filter { !queuedMessageIDs.contains($0.id) }
    }

    var currentSessionQueuedPrompts: [ChatQueuedPrompt] {
        requestQueue.enumerated().compactMap { index, queuedRequest in
            guard queuedRequest.sessionID == currentSessionID,
                  let message = message(queuedRequest.userMessageID, in: queuedRequest.sessionID)
            else {
                return nil
            }
            return ChatQueuedPrompt(
                id: queuedRequest.id,
                content: message.content,
                attachmentCount: message.imageAttachments.count,
                position: index + 1
            )
        }
    }

    func isSessionBusy(_ sessionID: UUID) -> Bool {
        activeRequestSessionID == sessionID
            || requestQueue.contains(where: { $0.sessionID == sessionID })
    }

    func canSend(isRunning: Bool, selectedModelID: String?) -> Bool {
        isRunning
            && selectedModelID?.isEmpty == false
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
        if activeRequestSessionID == currentSessionID {
            return "Working..."
        }
        return nil
    }

    func createSession() {
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

        persistCurrentSession(updateTimestamp: false)
        storedSessions.append(session)
        pruneRedundantEmptySessions()
        sessionStore.saveSession(session)
        draft = ""
        pendingImageAttachments.removeAll()
        applyCurrentSession(session)
    }

    func selectSession(_ sessionID: UUID) {
        guard sessionID != currentSessionID else {
            return
        }

        if let session = storedSessions.first(where: { $0.id == sessionID }) {
            persistCurrentSession(updateTimestamp: false)
            draft = ""
            pendingImageAttachments.removeAll()
            applyCurrentSession(session)
            return
        }

        if let session = sessionStore.loadSession(id: sessionID) {
            persistCurrentSession(updateTimestamp: false)
            upsertStoredSession(session)
            draft = ""
            pendingImageAttachments.removeAll()
            applyCurrentSession(session)
        }
    }

    func renameSession(_ sessionID: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = storedSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        storedSessions[index].customTitle = trimmed.isEmpty ? nil : trimmed
        if currentSession?.id == sessionID {
            currentSession?.customTitle = trimmed.isEmpty ? nil : trimmed
        }
        sessionStore.saveSession(storedSessions[index])
        refreshSessionList()
    }

    func deleteSession(_ sessionID: UUID) {
        guard !isSessionBusy(sessionID) else {
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
        let device = appModel.cpuIsRunning ? targetDevice : .gpu
        let deviceIsRunning = device == .cpu ? appModel.cpuIsRunning : appModel.isRunning
        let deviceModelID = device == .cpu ? appModel.cpuChatModelID : settings.languageModelID
        guard canSend(isRunning: deviceIsRunning, selectedModelID: deviceModelID),
              let modelID = deviceModelID,
              let currentSession
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
        self.currentSession?.lastInferenceDevice = device.rawValue
        persistCurrentSession(updateTimestamp: true)
        self.appModel = appModel
        let isImage = activeModelIsImageGeneration
        let requestPort = settings.serverPort
        requestQueue.append(QueuedChatRequest(
            id: UUID(),
            sessionID: currentSession.id,
            userMessageID: userMessage.id,
            assistantMessageID: UUID(),
            settings: settings,
            modelID: modelID,
            device: device,
            baseURL: URL(string: "http://127.0.0.1:\(requestPort)")!,
            isImageGeneration: isImage,
            imageWidth: imageGenerationWidth,
            imageHeight: imageGenerationHeight,
            referenceAttachment: isImage ? imageAttachments.first : nil
        ))
        bumpScroll()
        startNextRequestIfNeeded()
    }

    func cancel() {
        activeTask?.cancel()
    }

    func prioritizeQueuedRequest(_ requestID: UUID) {
        guard let index = requestQueue.firstIndex(where: { $0.id == requestID }), index > 0 else {
            return
        }
        let queuedRequest = requestQueue.remove(at: index)
        requestQueue.insert(queuedRequest, at: 0)
    }

    func steerQueuedRequest(_ requestID: UUID) {
        guard requestQueue.contains(where: { $0.id == requestID }) else {
            return
        }
        prioritizeQueuedRequest(requestID)
        activeTask?.cancel()
    }

    func removeQueuedRequest(_ requestID: UUID) {
        guard let index = requestQueue.firstIndex(where: { $0.id == requestID }) else {
            return
        }
        let queuedRequest = requestQueue.remove(at: index)
        removeMessage(queuedRequest.userMessageID, from: queuedRequest.sessionID)
        persistSession(queuedRequest.sessionID, updateTimestamp: true)
        if currentSessionID == queuedRequest.sessionID {
            bumpScroll()
        }
    }

    func captureScreenshotAttachment() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativ-screenshot-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", url.path]
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let attachment = try? ChatImageAttachment(contentsOf: url)
                else {
                    return
                }
                self.pendingImageAttachments.append(attachment)
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? process.run()
    }

    func chooseImageAttachments() {
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

    func captureScreenRecordingAttachment() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativ-recording-\(UUID().uuidString).mov")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-v", url.path]
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      FileManager.default.fileExists(atPath: url.path),
                      let attachment = try? ChatImageAttachment(contentsOf: url)
                else {
                    return
                }
                self.pendingImageAttachments.append(attachment)
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? process.run()
    }

    @discardableResult
    func pasteImagesFromClipboard() -> Bool {
        let pasteboard = NSPasteboard.general
        var attachments: [ChatImageAttachment] = []

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            attachments = urls.compactMap { try? ChatImageAttachment(contentsOf: $0) }
        }

        if attachments.isEmpty,
           let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            for image in images {
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else {
                    continue
                }
                attachments.append(
                    ChatImageAttachment(
                        filename: "pasted-\(UUID().uuidString.prefix(8)).png",
                        mimeType: "image/png",
                        base64Data: png.base64EncodedString()
                    )
                )
            }
        }

        guard !attachments.isEmpty else {
            return false
        }
        pendingImageAttachments.append(contentsOf: attachments)
        return true
    }

    func conversationText(for sessionID: UUID) -> String? {
        guard let session = storedSessions.first(where: { $0.id == sessionID }) else {
            return nil
        }
        var lines = [session.displayTitle, ""]
        for message in session.messages {
            let speaker: String
            switch message.role {
            case .user:
                speaker = "You"
            case .assistant:
                speaker = message.modelID.map { NativFormatting.truncateModelName($0, maxLength: 60) } ?? "Assistant"
            case .error:
                speaker = "Error"
            }
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty && message.imageAttachments.isEmpty {
                continue
            }
            lines.append("\(speaker):")
            if !message.imageAttachments.isEmpty {
                let count = message.imageAttachments.count
                lines.append("[\(count) attachment\(count == 1 ? "" : "s")]")
            }
            if !content.isEmpty {
                lines.append(content)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func removePendingImageAttachment(_ id: UUID) {
        pendingImageAttachments.removeAll { $0.id == id }
    }

    func clear() {
        activeTask?.cancel()
        activeTask = nil
        activeRequestID = nil
        activeRequestSessionID = nil
        requestQueue.removeAll()
        sendingStartedAt = nil
        draft = ""
        pendingImageAttachments.removeAll()
        messages.removeAll()
        persistCurrentSession(updateTimestamp: true)
        bumpScroll()
    }

    private func startNextRequestIfNeeded() {
        guard activeTask == nil else {
            return
        }

        while !requestQueue.isEmpty {
            let queuedRequest = requestQueue.removeFirst()
            let completionRequest = queuedRequest.isImageGeneration
                ? nil
                : makeCompletionRequest(for: queuedRequest)
            guard queuedRequest.isImageGeneration || completionRequest != nil,
                  insertAssistantMessage(for: queuedRequest)
            else {
                continue
            }

            activeRequestID = queuedRequest.id
            activeRequestSessionID = queuedRequest.sessionID
            sendingStartedAt = Date()
            if currentSessionID == queuedRequest.sessionID {
                bumpScroll()
            }

            activeTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                do {
                    if queuedRequest.isImageGeneration {
                        try await runImageGeneration(queuedRequest)
                    } else if let completionRequest {
                        let requestClient = NativChatClient(baseURL: queuedRequest.baseURL)
                        let completion = try await requestClient.streamChat(completionRequest, onEvent: { [weak self] event in
                            await MainActor.run {
                                self?.append(
                                    event: event,
                                    to: queuedRequest.assistantMessageID,
                                    in: queuedRequest.sessionID
                                )
                            }
                        })
                        finishAssistantMessage(
                            queuedRequest.assistantMessageID,
                            in: queuedRequest.sessionID,
                            fallbackContent: completion.content,
                            fallbackReasoningContent: completion.reasoningContent,
                            responseMetrics: ChatResponseMetrics(completion: completion),
                            isCancelled: false
                        )
                    }
                    appModel?.refreshMetricsIfRunning(force: true)
                } catch is CancellationError {
                    finishAssistantMessage(
                        queuedRequest.assistantMessageID,
                        in: queuedRequest.sessionID,
                        fallbackContent: "Response cancelled.",
                        fallbackReasoningContent: nil,
                        responseMetrics: nil,
                        isCancelled: true
                    )
                } catch {
                    failAssistantMessage(
                        queuedRequest.assistantMessageID,
                        in: queuedRequest.sessionID,
                        error: error
                    )
                    appModel?.refreshMetricsIfRunning(force: true)
                }

                guard activeRequestID == queuedRequest.id else {
                    return
                }
                activeRequestID = nil
                activeRequestSessionID = nil
                sendingStartedAt = nil
                activeTask = nil
                if currentSessionID == queuedRequest.sessionID {
                    bumpScroll()
                }
                startNextRequestIfNeeded()
            }
            return
        }
    }

    private func makeCompletionRequest(for queuedRequest: QueuedChatRequest) -> MLXChatCompletionRequest? {
        let modelID = queuedRequest.modelID
        guard let sessionMessages = sessionMessages(for: queuedRequest.sessionID),
              let userMessageIndex = sessionMessages.firstIndex(where: { $0.id == queuedRequest.userMessageID })
        else {
            return nil
        }

        var requestMessages = sessionMessages[...userMessageIndex].compactMap(\.apiMessage)
        if !queuedRequest.settings.systemPrompt.isEmpty {
            requestMessages.insert(
                MLXChatMessage(role: "system", content: queuedRequest.settings.systemPrompt),
                at: 0
            )
        }

        let settings = queuedRequest.settings
        return MLXChatCompletionRequest(
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
            stream: true,
            device: queuedRequest.device == .cpu ? "cpu" : "gpu"
        )
    }

    private func insertAssistantMessage(for queuedRequest: QueuedChatRequest) -> Bool {
        let assistantMessage = ChatTranscriptMessage(
            id: queuedRequest.assistantMessageID,
            role: .assistant,
            content: "",
            modelID: queuedRequest.settings.languageModelID,
            isStreaming: true,
            isThinkingEnabled: queuedRequest.settings.thinkingEnabled
        )

        if currentSessionID == queuedRequest.sessionID {
            guard let userMessageIndex = messages.firstIndex(where: { $0.id == queuedRequest.userMessageID }) else {
                return false
            }
            messages.insert(assistantMessage, at: userMessageIndex + 1)
            return true
        }

        guard let sessionIndex = storedSessions.firstIndex(where: { $0.id == queuedRequest.sessionID }),
              let userMessageIndex = storedSessions[sessionIndex].messages.firstIndex(
                where: { $0.id == queuedRequest.userMessageID }
              )
        else {
            return false
        }
        storedSessions[sessionIndex].messages.insert(assistantMessage, at: userMessageIndex + 1)
        return true
    }

    private func sessionMessages(for sessionID: UUID) -> [ChatTranscriptMessage]? {
        if currentSessionID == sessionID {
            return messages
        }
        return storedSessions.first(where: { $0.id == sessionID })?.messages
    }

    private func message(_ messageID: UUID, in sessionID: UUID) -> ChatTranscriptMessage? {
        sessionMessages(for: sessionID)?.first(where: { $0.id == messageID })
    }

    private func removeMessage(_ messageID: UUID, from sessionID: UUID) {
        if currentSessionID == sessionID {
            messages.removeAll { $0.id == messageID }
            return
        }
        guard let sessionIndex = storedSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        storedSessions[sessionIndex].messages.removeAll { $0.id == messageID }
    }

    private func append(event: MLXChatStreamDelta, to id: UUID, in sessionID: UUID) {
        // Accumulate deltas and flush to the published message at a capped
        // cadence. Applying every token synchronously saturates the main run
        // loop, freezing the transcript, thinking bubble, and "Working"
        // animation until an input event (issue #11 / upstream #48).
        if let reasoningContent = event.reasoningContent, !reasoningContent.isEmpty {
            pendingStreamReasoning[id, default: ""] += reasoningContent
        }
        if let content = event.content, !content.isEmpty {
            pendingStreamContent[id, default: ""] += content
        }
        if shouldRefreshLiveDecodeRate(event.decodeTokensPerSecond, for: id),
           let decodeTokensPerSecond = event.decodeTokensPerSecond {
            pendingStreamDecodeRate[id] = decodeTokensPerSecond
        }

        guard hasPendingStreamUpdate(id) else {
            return
        }

        let now = Date()
        if let lastFlush = streamFlushDates[id],
           now.timeIntervalSince(lastFlush) < Self.streamFlushInterval {
            scheduleStreamFlush(id, in: sessionID)
            return
        }
        flushStream(id, in: sessionID)
    }

    private func hasPendingStreamUpdate(_ id: UUID) -> Bool {
        pendingStreamContent[id]?.isEmpty == false
            || pendingStreamReasoning[id]?.isEmpty == false
            || pendingStreamDecodeRate[id] != nil
    }

    private func scheduleStreamFlush(_ id: UUID, in sessionID: UUID) {
        guard streamFlushTasks[id] == nil else {
            return
        }
        streamFlushTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.streamFlushInterval * 1_000_000_000))
            guard let self, !Task.isCancelled else {
                return
            }
            self.streamFlushTasks[id] = nil
            self.flushStream(id, in: sessionID)
        }
    }

    private func flushStream(_ id: UUID, in sessionID: UUID) {
        streamFlushTasks[id]?.cancel()
        streamFlushTasks[id] = nil

        let content = pendingStreamContent.removeValue(forKey: id) ?? ""
        let reasoning = pendingStreamReasoning.removeValue(forKey: id) ?? ""
        let decodeRate = pendingStreamDecodeRate.removeValue(forKey: id)
        guard !content.isEmpty || !reasoning.isEmpty || decodeRate != nil else {
            return
        }

        updateMessage(id, in: sessionID) { message in
            if !reasoning.isEmpty {
                message.reasoningContent.append(reasoning)
            }
            if !content.isEmpty {
                if !message.reasoningContent.isEmpty, message.thinkingDuration == nil {
                    message.thinkingDuration = Date().timeIntervalSince(message.createdAt)
                }
                message.content.append(content)
            }
            if let decodeRate {
                message.responseMetrics = ChatResponseMetrics(
                    totalTokens: message.responseMetrics?.totalTokens,
                    decodeTokensPerSecond: decodeRate,
                    peakMemoryGB: message.responseMetrics?.peakMemoryGB
                )
            }
        }
        streamFlushDates[id] = Date()
        if (!content.isEmpty || !reasoning.isEmpty), currentSessionID == sessionID {
            bumpScroll()
        }
    }

    private func clearStreamBuffers(_ id: UUID) {
        streamFlushTasks[id]?.cancel()
        streamFlushTasks.removeValue(forKey: id)
        pendingStreamContent.removeValue(forKey: id)
        pendingStreamReasoning.removeValue(forKey: id)
        pendingStreamDecodeRate.removeValue(forKey: id)
        streamFlushDates.removeValue(forKey: id)
    }

    private func shouldRefreshLiveDecodeRate(
        _ decodeTokensPerSecond: Double?,
        for messageID: UUID
    ) -> Bool {
        guard let decodeTokensPerSecond,
              decodeTokensPerSecond > 0,
              decodeTokensPerSecond.isFinite
        else {
            return false
        }

        let now = Date()
        if let lastRefresh = liveDecodeRateRefreshDates[messageID],
           now.timeIntervalSince(lastRefresh) < Self.liveDecodeRateRefreshInterval {
            return false
        }

        liveDecodeRateRefreshDates[messageID] = now
        return true
    }

    private func finishAssistantMessage(
        _ id: UUID,
        in sessionID: UUID,
        fallbackContent: String,
        fallbackReasoningContent: String?,
        responseMetrics: ChatResponseMetrics?,
        isCancelled: Bool
    ) {
        flushStream(id, in: sessionID)
        clearStreamBuffers(id)
        liveDecodeRateRefreshDates.removeValue(forKey: id)
        updateMessage(id, in: sessionID) { message in
            message.isStreaming = false
            if message.content.isEmpty {
                message.content = fallbackContent
            }
            if message.reasoningContent.isEmpty,
               let fallbackReasoningContent {
                message.reasoningContent = fallbackReasoningContent
            }
            if !message.reasoningContent.isEmpty,
               message.thinkingDuration == nil {
                message.thinkingDuration = Date().timeIntervalSince(message.createdAt)
            }
            if isCancelled,
               message.content == fallbackContent,
               message.reasoningContent.isEmpty {
                message.role = .error
            }
            message.responseMetrics = responseMetrics?.hasVisibleValues == true
                ? responseMetrics
                : nil
        }
        persistSession(sessionID, updateTimestamp: true)
    }

    private func runImageGeneration(_ queuedRequest: QueuedChatRequest) async throws {
        guard let promptMessage = message(queuedRequest.userMessageID, in: queuedRequest.sessionID) else {
            throw NativImageError.missingImageData
        }
        let prompt = promptMessage.content
        let client = NativImageClient(baseURL: queuedRequest.baseURL)
        let steps = 4
        let startedAt = Date()
        let response: MLXImageResponse
        if let reference = queuedRequest.referenceAttachment,
           let referenceURL = writeTemporaryImage(reference) {
            response = try await client.edit(MLXImageEditRequest(
                model: queuedRequest.modelID,
                prompt: prompt,
                image: [referenceURL.path],
                n: 1,
                width: queuedRequest.imageWidth,
                height: queuedRequest.imageHeight,
                steps: steps
            ))
        } else {
            response = try await client.generate(MLXImageGenerationRequest(
                model: queuedRequest.modelID,
                prompt: prompt,
                n: 1,
                width: queuedRequest.imageWidth,
                height: queuedRequest.imageHeight,
                steps: steps
            ))
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let attachments = Self.generatedAttachments(from: response)
        guard !attachments.isEmpty else {
            throw NativImageError.missingImageData
        }
        finishImageMessage(
            queuedRequest.assistantMessageID,
            in: queuedRequest.sessionID,
            generatedImages: attachments,
            metrics: ImageGenerationMetrics(
                imageCount: attachments.count,
                steps: steps,
                totalSeconds: elapsed
            )
        )
    }

    private func finishImageMessage(
        _ id: UUID,
        in sessionID: UUID,
        generatedImages: [ChatImageAttachment],
        metrics: ImageGenerationMetrics
    ) {
        updateMessage(id, in: sessionID) { message in
            message.isStreaming = false
            message.generatedImages = generatedImages
            message.imageGenerationMetrics = metrics
        }
        persistSession(sessionID, updateTimestamp: true)
    }

    private func writeTemporaryImage(_ attachment: ChatImageAttachment) -> URL? {
        guard let data = attachment.imageData else {
            return nil
        }
        let providedExtension = (attachment.filename as NSString).pathExtension
        let fileExtension = providedExtension.isEmpty ? "png" : providedExtension
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private static func generatedAttachments(from response: MLXImageResponse) -> [ChatImageAttachment] {
        response.data.compactMap { item -> ChatImageAttachment? in
            let base64: String
            if let encoded = item.b64JSON, !encoded.isEmpty {
                base64 = encoded
            } else if let path = item.path,
                      let fileData = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                base64 = fileData.base64EncodedString()
            } else {
                return nil
            }
            guard let data = Data(base64Encoded: base64), NSImage(data: data) != nil else {
                return nil
            }
            let fileExtension = item.mimeType.contains("jpeg") ? "jpg" : "png"
            return ChatImageAttachment(
                filename: "generated-\(item.seed).\(fileExtension)",
                mimeType: item.mimeType,
                base64Data: base64
            )
        }
    }

    private func failAssistantMessage(_ id: UUID, in sessionID: UUID, error: Error) {
        clearStreamBuffers(id)
        liveDecodeRateRefreshDates.removeValue(forKey: id)
        guard updateMessage(id, in: sessionID, mutate: { message in
            message.role = .error
            message.content = error.localizedDescription
            message.isStreaming = false
            if !message.reasoningContent.isEmpty,
               message.thinkingDuration == nil {
                message.thinkingDuration = Date().timeIntervalSince(message.createdAt)
            }
        }) else {
            return
        }
        persistSession(sessionID, updateTimestamp: true)
    }

    @discardableResult
    private func updateMessage(
        _ messageID: UUID,
        in sessionID: UUID,
        mutate: (inout ChatTranscriptMessage) -> Void
    ) -> Bool {
        if currentSessionID == sessionID {
            guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }) else {
                return false
            }
            mutate(&messages[messageIndex])
            return true
        }

        guard let sessionIndex = storedSessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = storedSessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID })
        else {
            return false
        }

        mutate(&storedSessions[sessionIndex].messages[messageIndex])
        return true
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

    private func persistSession(_ sessionID: UUID, updateTimestamp: Bool) {
        if sessionID == currentSessionID {
            persistCurrentSession(updateTimestamp: updateTimestamp)
            return
        }

        guard let index = storedSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }

        storedSessions[index].title = ChatSession.defaultTitle(
            for: storedSessions[index].messages,
            createdAt: storedSessions[index].createdAt
        )
        if updateTimestamp {
            storedSessions[index].updatedAt = Date()
        }
        sessionStore.saveSession(storedSessions[index])
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

private struct ChatMessageModelIcon: View {
    let provider: LocalModelProvider
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if provider.needsLightIconBackgroundInDarkMode, colorScheme == .dark {
                Circle()
                    .fill(Color.white.opacity(0.94))
                    .frame(width: 14, height: 14)
            }

            if let image = LocalModelProviderIcon.image(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color(nsColor: provider.iconTintColor))
                    .frame(width: 11, height: 11)
            } else {
                Text(provider.monogram)
                    .font(.system(size: provider.monogram.count > 2 ? 5 : 7, weight: .bold))
                    .foregroundStyle(Color(nsColor: provider.iconTintColor))
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

private struct ChatMessageRow: View {
    private static let maximumUserBubbleWidth: CGFloat = 560

    let message: ChatTranscriptMessage
    @State private var didCopyResponse = false
    @State private var isHoveringMessage = false

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            if !title.isEmpty {
                HStack(spacing: 5) {
                    if message.role == .assistant, let provider = messageProvider {
                        ChatMessageModelIcon(provider: provider)
                    }
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

                if !message.generatedImages.isEmpty {
                    ChatGeneratedImages(attachments: message.generatedImages)
                    if let imageMetrics = message.imageGenerationMetrics {
                        ChatImageGenerationMetricsRow(metrics: imageMetrics)
                    }
                }
            }

            if let liveDecodeTokensPerSecond {
                ChatLiveDecodeRateBadge(tokensPerSecond: liveDecodeTokensPerSecond)
                    .equatable()
            } else if let responseMetrics {
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
        .frame(maxWidth: bubbleMaximumWidth, alignment: alignment)
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

    private var messageProvider: LocalModelProvider? {
        guard message.role == .assistant, let modelID = message.modelID else {
            return nil
        }
        return LocalModelProviderResolver.resolve(
            repoID: modelID,
            modelType: nil,
            architectures: []
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

    private var bubbleMaximumWidth: CGFloat? {
        message.role == .user && !usesCompactBubble ? Self.maximumUserBubbleWidth : nil
    }

    private var alignment: Alignment {
        .leading
    }

    private var textAlignment: TextAlignment {
        .leading
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

    private var liveDecodeTokensPerSecond: Double? {
        guard message.role == .assistant,
              message.isStreaming,
              let decodeTokensPerSecond = message.responseMetrics?.decodeTokensPerSecond,
              decodeTokensPerSecond > 0,
              decodeTokensPerSecond.isFinite
        else {
            return nil
        }

        return decodeTokensPerSecond
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

private struct ChatLiveDecodeRateBadge: View, Equatable {
    let tokensPerSecond: Double

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)

            Text("Live decode")
                .foregroundStyle(.secondary)

            Text(NativFormatting.rate(tokensPerSecond))
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(0.1))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live decode speed")
        .accessibilityValue(NativFormatting.rate(tokensPerSecond))
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
                .fill(Color.nativPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .help("\(label): \(value)")
    }
}

private func saveGeneratedImage(_ attachment: ChatImageAttachment) {
    guard let data = attachment.imageData else {
        return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = attachment.filename
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else {
        return
    }
    try? data.write(to: url)
}

private struct ChatGeneratedImages: View {
    let attachments: [ChatImageAttachment]
    @State private var fullscreenAttachment: ChatImageAttachment?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(attachments) { attachment in
                ChatGeneratedImageThumbnail(attachment: attachment) {
                    fullscreenAttachment = attachment
                }
            }
        }
        .sheet(item: $fullscreenAttachment) { attachment in
            ChatGeneratedImageFullscreen(attachment: attachment) {
                fullscreenAttachment = nil
            }
        }
    }
}

private struct ChatGeneratedImageThumbnail: View {
    let attachment: ChatImageAttachment
    let onExpand: () -> Void
    @State private var isHovering = false

    private var nsImage: NSImage? {
        attachment.imageData.flatMap(NSImage.init(data:))
    }

    var body: some View {
        if let nsImage {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 320)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if isHovering {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.12))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isHovering {
                        Button {
                            saveGeneratedImage(attachment)
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.black.opacity(0.75))
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(0.85), in: Circle())
                                .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .help("Download image")
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onTapGesture(perform: onExpand)
                .onHover { isHovering = $0 }
                .animation(.easeInOut(duration: 0.12), value: isHovering)
        }
    }
}

private struct ChatGeneratedImageFullscreen: View {
    let attachment: ChatImageAttachment
    let onDismiss: () -> Void

    private var nsImage: NSImage? {
        attachment.imageData.flatMap(NSImage.init(data:))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .onExitCommand(perform: onDismiss)
    }
}

private struct ChatImageGenerationMetricsRow: View {
    let metrics: ImageGenerationMetrics

    var body: some View {
        HStack(spacing: 12) {
            metric("Time", seconds: metrics.totalSeconds)
            metric("Per image", seconds: metrics.secondsPerImage)
            if let stepsPerSecond = metrics.stepsPerSecond {
                metric("Steps/s", value: String(format: "%.1f", stepsPerSecond))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func metric(_ title: String, seconds: Double) -> some View {
        let value = seconds >= 10
            ? String(format: "%.0fs", seconds)
            : String(format: "%.1fs", seconds)
        return metric(title, value: value)
    }

    private func metric(_ title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.tertiary)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
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
                .background(Color.nativPanel)
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
        VStack(spacing: 16) {
            Image("NativMark")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 64)
                .foregroundStyle(Color.nativMark)

            VStack(spacing: 7) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
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
    ChatView(model: .init(), chat: ChatViewModel(), showsConfiguration: .constant(true))
}
