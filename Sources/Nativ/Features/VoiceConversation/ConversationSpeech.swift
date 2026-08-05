import AVFoundation
import Combine
import Foundation

/// Speaks the assistant's replies and publishes a 0…1 level for the orb's output
/// volume. The level is a speech-shaped envelope gated by real start/finish
/// callbacks — enough to animate the orb convincingly without decoding the
/// synthesizer's audio buffers. Real output metering can replace the envelope
/// later without changing this surface.
@MainActor
final class ConversationSpeech: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var level: Float = 0

    private let synthesizer = AVSpeechSynthesizer()
    private var envelopeTimer: Timer?
    private var phase: Float = 0
    private var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speak `text`; `onFinish` fires when speech completes (not on interrupt).
    func speak(_ text: String, onFinish: @escaping () -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onFinish(); return }
        self.onFinish = onFinish
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
    }

    /// Interrupt current speech (e.g. the user barges in or ends the session).
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        finishEnvelope()
        onFinish = nil
    }

    // MARK: - Envelope

    private func startEnvelope() {
        envelopeTimer?.invalidate()
        phase = 0
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickEnvelope() }
        }
        RunLoop.main.add(timer, forMode: .common)
        envelopeTimer = timer
    }

    private func tickEnvelope() {
        phase += 0.32
        let base = sin(phase * 2.3) * 0.3 + 0.5
        let micro = sin(phase * 13) * 0.12
        level = max(0.05, min(1, base + micro))
    }

    private func finishEnvelope() {
        envelopeTimer?.invalidate()
        envelopeTimer = nil
        isSpeaking = false
        level = 0
    }
}

extension ConversationSpeech: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didStart _: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = true
            startEnvelope()
        }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        Task { @MainActor in
            finishEnvelope()
            let callback = onFinish
            onFinish = nil
            callback?()
        }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        Task { @MainActor in finishEnvelope() }
    }
}
