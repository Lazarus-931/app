import AVFoundation
import Foundation
import Speech

/// Hands-free speech recognition for the voice session. Listens continuously and,
/// after a short pause following speech, reports the finalized utterance and stops
/// its capture cycle. The session controller starts a fresh cycle for each turn so
/// the microphone can be paused while the model is speaking (avoiding echo).
@MainActor
final class VoiceSpeechRecognizer: ObservableObject {
    /// Smoothed microphone input level (0...1) while listening, for the orb.
    @Published private(set) var level: Double = 0
    @Published var errorMessage: String?

    /// Fired with the finalized transcript once the speaker pauses.
    var onUtterance: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var latestTranscript = ""
    private var isListening = false

    /// The pause (seconds) after the last recognized speech that ends a turn.
    private let endOfTurnSilence: TimeInterval = 1.3

    func start() {
        guard !isListening else {
            return
        }
        errorMessage = nil
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                guard status == .authorized else {
                    self.errorMessage = "Speech recognition permission was declined. Enable it in System Settings › Privacy & Security."
                    return
                }
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else {
                    self.errorMessage = "Microphone permission was declined. Enable it in System Settings › Privacy & Security."
                    return
                }
                self.beginCycle()
            }
        }
    }

    /// Stop the current capture cycle without reporting an utterance.
    func stop() {
        endCycle()
        level = 0
    }

    private func beginCycle() {
        guard !isListening else {
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            errorMessage = "Speech recognition is unavailable on this Mac."
            return
        }

        latestTranscript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            let rms = Self.rms(buffer)
            Task { @MainActor [weak self] in
                self?.updateLevel(rms)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.request = nil
            errorMessage = "Could not start the microphone: \(error.localizedDescription)"
            return
        }

        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else {
                    return
                }
                if let result {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        self.latestTranscript = text
                        self.scheduleEndOfTurn()
                    }
                }
                if error != nil {
                    self.finishTurn()
                }
            }
        }
    }

    private func scheduleEndOfTurn() {
        silenceTimer?.invalidate()
        let timer = Timer(timeInterval: endOfTurnSilence, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishTurn()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    private func finishTurn() {
        let transcript = latestTranscript
        endCycle()
        level = 0
        if !transcript.isEmpty {
            onUtterance?(transcript)
        }
    }

    private func endCycle() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        request?.endAudio()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        latestTranscript = ""
    }

    private func updateLevel(_ rms: Float) {
        // Perceptual mapping so ordinary speech clearly drives the orb: quiet speech
        // still registers and loud speech saturates. Snappy smoothing tracks the
        // cadence of speech rather than lagging behind it.
        let boosted = Double(rms) * 16.0
        let scaled = min(1.0, pow(max(0.0, boosted), 0.7))
        level = level * 0.4 + scaled * 0.6
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0 else {
            return 0
        }
        if let channelData = buffer.floatChannelData {
            let channel = channelData[0]
            var sum: Float = 0
            for index in 0..<count {
                let sample = channel[index]
                sum += sample * sample
            }
            return (sum / Float(count)).squareRoot()
        }
        // Fallback for non-float input formats so the level never silently stays at 0.
        if let channelData = buffer.int16ChannelData {
            let channel = channelData[0]
            var sum: Float = 0
            for index in 0..<count {
                let sample = Float(channel[index]) / Float(Int16.max)
                sum += sample * sample
            }
            return (sum / Float(count)).squareRoot()
        }
        return 0
    }
}
