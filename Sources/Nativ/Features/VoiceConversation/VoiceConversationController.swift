import Combine
import SwiftUI

/// Drives full voice-conversation mode: the listening → thinking → speaking
/// loop, publishing the signals the orb and conversation view bind to.
///
/// - Listening: on-device dictation (`ChatDictationController`) streams partial
///   transcripts; the mic level feeds the orb. A short pause (no new words)
///   ends the turn.
/// - Thinking: the transcript is sent through the existing chat pipeline; the
///   streaming reply becomes the caption.
/// - Speaking: the finished reply is spoken (`ConversationSpeech`) and its
///   envelope feeds the orb, then the loop returns to listening.
@MainActor
final class VoiceConversationController: ObservableObject {
    @Published private(set) var state: VisualizerAgentState = .connecting
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var outputLevel: Float = 0
    @Published private(set) var caption: String = ""
    @Published private(set) var isMuted: Bool = false

    private let chat: ChatViewModel
    private let model: NativModel
    private let dictation = ChatDictationController()
    private let speech = ConversationSpeech()

    private var cancellables = Set<AnyCancellable>()
    private var silenceTimer: Timer?
    private var latestTranscript = ""
    private var active = false

    /// How long the user can pause before we treat their turn as finished.
    private let endOfTurnSilence: TimeInterval = 1.5

    init(chat: ChatViewModel, model: NativModel) {
        self.chat = chat
        self.model = model

        dictation.$level
            .sink { [weak self] level in self?.inputLevel = level }
            .store(in: &cancellables)
        speech.$level
            .sink { [weak self] level in self?.outputLevel = level }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func start() {
        guard !active else { return }
        active = true
        chat.onAssistantResponsePartial = { [weak self] partial in
            Task { @MainActor in self?.handleAssistantPartial(partial) }
        }
        chat.onAssistantResponseFinished = { [weak self] full in
            Task { @MainActor in self?.handleAssistantFinished(full) }
        }
        beginListening()
    }

    func stop() {
        active = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        dictation.stop()
        speech.stop()
        chat.onAssistantResponsePartial = nil
        chat.onAssistantResponseFinished = nil
        state = .disconnected
        inputLevel = 0
        outputLevel = 0
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            silenceTimer?.invalidate()
            dictation.stop()
            inputLevel = 0
        } else if state == .listening {
            beginListening()
        }
    }

    // MARK: - Listening

    private func beginListening() {
        guard active, !isMuted else { return }
        state = .listening
        caption = ""
        latestTranscript = ""
        dictation.toggle(baseText: "") { [weak self] transcript in
            Task { @MainActor in self?.handleUserTranscript(transcript) }
        }
    }

    private func handleUserTranscript(_ transcript: String) {
        guard active, state == .listening else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        latestTranscript = text
        caption = text
        resetSilenceTimer()
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        let timer = Timer(timeInterval: endOfTurnSilence, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endUserTurn() }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    private func endUserTurn() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        guard active, state == .listening else { return }
        dictation.stop()
        let text = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            beginListening()
            return
        }
        submit(text)
    }

    // MARK: - Thinking / speaking

    private func submit(_ text: String) {
        state = .thinking
        caption = text
        chat.draft = text
        chat.send(using: model)
    }

    private func handleAssistantPartial(_ partial: String) {
        guard active, state == .thinking else { return }
        caption = partial
    }

    private func handleAssistantFinished(_ full: String) {
        guard active else { return }
        state = .speaking
        caption = full
        speech.speak(full) { [weak self] in
            Task { @MainActor in self?.assistantDidFinishSpeaking() }
        }
    }

    private func assistantDidFinishSpeaking() {
        guard active else { return }
        beginListening()
    }
}
