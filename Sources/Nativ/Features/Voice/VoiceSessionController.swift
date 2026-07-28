import Foundation
import NativServerKit

/// Orchestrates a hands-free voice conversation: listen → (pause) → send the turn
/// to the chat model → speak the reply → resume listening. The microphone is paused
/// while the model is thinking/speaking to avoid it transcribing its own voice.
@MainActor
final class VoiceSessionController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isActive = false
    @Published var isMinimized = false
    /// Amplitude (0...1) of your microphone — drives the warm, bottom-right lobe of the orb.
    @Published private(set) var userLevel: Double = 0
    /// Amplitude (0...1) of the model's speech playback — drives the cool, top-left lobe.
    @Published private(set) var modelLevel: Double = 0
    @Published private(set) var statusText = ""

    let recognizer = VoiceSpeechRecognizer()
    let player = VoiceAudioPlayer()

    private let modelRecognizer = ModelSpeechRecognizer()
    private var usesModelSTT = false
    private weak var chat: ChatViewModel?
    private weak var appModel: NativModel?
    private var levelTimer: Timer?
    private lazy var speechQueue = VoiceSpeechQueue(player: player)
    private var chunker = SentenceChunker()
    private var streamingTTS = false

    func start(chat: ChatViewModel, model: NativModel) {
        guard !isActive else {
            return
        }
        self.chat = chat
        self.appModel = model
        isActive = true
        isMinimized = false

        usesModelSTT = configureModelRecognizer(model)
        let handleUtterance: (String) -> Void = { [weak self] text in
            self?.handleUtterance(text)
        }
        recognizer.onUtterance = handleUtterance
        modelRecognizer.onUtterance = handleUtterance
        chat.onAssistantResponsePartial = { [weak self] delta in
            self?.handlePartial(delta)
        }
        chat.onAssistantResponseFinished = { [weak self] _ in
            self?.handleResponseFinished()
        }
        speechQueue.synthesize = { [weak self] sentence in
            guard let self else {
                return nil
            }
            return await self.synthesizeSpeech(sentence)
        }
        speechQueue.onSpeakingStarted = { [weak self] in
            self?.phase = .speaking
            self?.statusText = "Speaking…"
        }
        speechQueue.onFinished = { [weak self] in
            self?.beginListening()
        }

        startLevelTracking()
        beginListening()
    }

    func stop() {
        recognizer.onUtterance = nil
        modelRecognizer.onUtterance = nil
        recognizer.stop()
        modelRecognizer.stop()
        player.stop()
        speechQueue.stop()
        chat?.onAssistantResponseFinished = nil
        chat?.onAssistantResponsePartial = nil
        levelTimer?.invalidate()
        levelTimer = nil
        isActive = false
        isMinimized = false
        phase = .idle
        userLevel = 0
        modelLevel = 0
        statusText = ""
    }

    func toggleMinimized() {
        isMinimized.toggle()
    }

    private func beginListening() {
        guard isActive else {
            return
        }
        phase = .listening
        statusText = "Listening…"
        if usesModelSTT {
            modelRecognizer.start()
        } else {
            recognizer.start()
        }
    }

    private func configureModelRecognizer(_ appModel: NativModel) -> Bool {
        let settings = appModel.settings.normalized()
        guard let sttModel = settings.speechToTextModelID else {
            return false
        }
        let onCPU = settings.speechToTextDevice == .cpu
        guard !onCPU || appModel.cpuIsRunning else {
            return false
        }
        let port = onCPU ? settings.cpuServerPort : settings.serverPort
        modelRecognizer.model = sttModel
        modelRecognizer.apiKey = settings.serverAPIKey
        modelRecognizer.baseURL = URL(string: "http://127.0.0.1:\(port)")
            ?? URL(string: "http://127.0.0.1:\(settings.serverPort)")!
        return true
    }

    private func handleUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isActive, !trimmed.isEmpty, let chat, let appModel else {
            return
        }
        // Pause the mic while the model thinks and speaks (prevents echo capture).
        if usesModelSTT {
            modelRecognizer.stop()
        } else {
            recognizer.stop()
        }
        phase = .thinking
        statusText = "Thinking…"
        streamingTTS = resolvedTTSModel(appModel) != nil
        chunker = SentenceChunker()
        if streamingTTS {
            speechQueue.begin()
        }
        chat.draft = trimmed
        chat.send(using: appModel)
    }

    private func handlePartial(_ delta: String) {
        guard isActive, streamingTTS else {
            return
        }
        for sentence in chunker.push(delta) {
            speechQueue.enqueue(sentence)
        }
    }

    private func handleResponseFinished() {
        guard isActive else {
            return
        }
        guard streamingTTS else {
            beginListening()
            return
        }
        if let tail = chunker.flush() {
            speechQueue.enqueue(tail)
        }
        speechQueue.finishGeneration()
    }

    private func synthesizeSpeech(_ sentence: String) async -> Data? {
        guard let appModel, let ttsModel = resolvedTTSModel(appModel) else {
            return nil
        }
        let client = NativAudioClient(
            baseURL: textToSpeechBaseURL(appModel),
            apiKey: appModel.settings.serverAPIKey
        )
        return try? await client.speech(MLXSpeechRequest(model: ttsModel, input: sentence))
    }

    private func resolvedTTSModel(_ appModel: NativModel) -> String? {
        let id = appModel.settings.normalized().textToSpeechModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty == false) ? id : nil
    }

    private func textToSpeechBaseURL(_ appModel: NativModel) -> URL {
        let settings = appModel.settings.normalized()
        let port = settings.textToSpeechDevice == .cpu && appModel.cpuIsRunning
            ? settings.cpuServerPort
            : settings.serverPort
        return URL(string: "http://127.0.0.1:\(port)")
            ?? URL(string: "http://127.0.0.1:8080")!
    }

    private func startLevelTracking() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                // Track the two voices independently so the orb can show both at once.
                self.userLevel = self.phase == .listening
                    ? (self.usesModelSTT ? self.modelRecognizer.level : self.recognizer.level)
                    : self.userLevel * 0.85
                self.modelLevel = self.phase == .speaking
                    ? self.player.level
                    : self.modelLevel * 0.85
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }
}
