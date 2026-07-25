import Foundation
import NativServerKit

/// Turns text into spoken audio via the local server's `/v1/audio/speech` endpoint
/// and plays it. Shared by the per-message read-aloud button and the voice session.
@MainActor
final class TextToSpeechService: ObservableObject {
    /// The message currently being read aloud, if any (drives the read-aloud button state).
    @Published private(set) var speakingMessageID: UUID?
    @Published private(set) var isSynthesizing = false
    @Published private(set) var lastError: String?

    let player = VoiceAudioPlayer()

    private var task: Task<Void, Never>?

    var isSpeaking: Bool {
        isSynthesizing || player.isPlaying
    }

    func isSpeaking(messageID: UUID) -> Bool {
        speakingMessageID == messageID && isSpeaking
    }

    /// Synthesize `text` with the given TTS model and play it. Returns immediately;
    /// playback happens asynchronously. Passing `messageID` lets the UI show which
    /// message is being read aloud.
    func speak(
        _ text: String,
        model: String,
        baseURL: URL,
        apiKey: String? = nil,
        voice: String? = nil,
        messageID: UUID? = nil,
        onFinish: (() -> Void)? = nil
    ) {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        lastError = nil
        speakingMessageID = messageID
        isSynthesizing = true

        task = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let client = NativAudioClient(baseURL: baseURL, apiKey: apiKey)
                let data = try await client.speech(
                    MLXSpeechRequest(model: model, input: trimmed, voice: voice)
                )
                if Task.isCancelled {
                    return
                }
                self.isSynthesizing = false
                try self.player.play(data) { [weak self] in
                    self?.speakingMessageID = nil
                    onFinish?()
                }
            } catch is CancellationError {
                return
            } catch {
                self.isSynthesizing = false
                self.speakingMessageID = nil
                self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player.stop()
        isSynthesizing = false
        speakingMessageID = nil
    }
}
