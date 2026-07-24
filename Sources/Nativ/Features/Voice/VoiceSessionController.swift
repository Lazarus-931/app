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
    /// Amplitude (0...1) driving the orb — mic level while listening, playback level while speaking.
    @Published private(set) var level: Double = 0
    @Published private(set) var statusText = ""

    let recognizer = VoiceSpeechRecognizer()
    let player = VoiceAudioPlayer()

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

        recognizer.onUtterance = { [weak self] text in
            self?.handleUtterance(text)
        }
        chat.onAssistantResponseFinished = { [weak self] text in
            self?.speak(text)
        }

        startLevelTracking()
        beginListening()
    }

    func stop() {
        recognizer.onUtterance = nil
        recognizer.stop()
        player.stop()
        chat?.onAssistantResponseFinished = nil
        levelTimer?.invalidate()
        levelTimer = nil
        isActive = false
        isMinimized = false
        phase = .idle
        level = 0
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
        recognizer.start()
    }

    private func handleUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isActive, !trimmed.isEmpty, let chat, let appModel else {
            return
        }
        // Pause the mic while the model thinks and speaks (prevents echo capture).
        recognizer.stop()
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
        let baseURL = serverBaseURL(appModel)
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let client = NativAudioClient(baseURL: baseURL)
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

    private func serverBaseURL(_ appModel: NativModel) -> URL {
        URL(string: "http://127.0.0.1:\(appModel.settings.normalized().serverPort)")
            ?? URL(string: "http://127.0.0.1:8080")!
    }

    private func startLevelTracking() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                switch self.phase {
                case .listening:
                    self.level = self.recognizer.level
                case .speaking:
                    self.level = self.player.level
                case .thinking, .idle:
                    self.level = self.level * 0.85
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }
}
