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
        chat.onAssistantResponseFinished = { [weak self] text in
            self?.speak(text)
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
        chat?.onAssistantResponseFinished = nil
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
        chat.draft = trimmed
        chat.send(using: appModel)
    }

    private func speak(_ text: String) {
        guard isActive else {
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            beginListening()
            return
        }
        guard let appModel,
              let ttsModel = resolvedTTSModel(appModel) else {
            // No TTS model configured — keep the conversation going without audio.
            beginListening()
            return
        }

        phase = .speaking
        statusText = "Speaking…"
        let baseURL = textToSpeechBaseURL(appModel)
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let client = NativAudioClient(baseURL: baseURL, apiKey: appModel.settings.serverAPIKey)
                let data = try await client.speech(MLXSpeechRequest(model: ttsModel, input: trimmed))
                guard self.isActive else {
                    return
                }
                try self.player.play(data) { [weak self] in
                    self?.beginListening()
                }
            } catch {
                if self.isActive {
                    self.beginListening()
                }
            }
        }
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
