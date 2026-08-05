import AVFoundation
import Speech
import SwiftUI

@MainActor
final class ChatDictationController: ObservableObject {
    @Published private(set) var isRecording = false
    /// Normalized 0…1 mic level from the capture tap, for visualizers.
    @Published private(set) var level: Float = 0
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var baseText = ""
    private var onTranscript: ((String) -> Void)?
    private var wantsRecording = false

    func toggle(baseText: String, onTranscript: @escaping (String) -> Void) {
        if isRecording || wantsRecording {
            stop()
        } else {
            start(baseText: baseText, onTranscript: onTranscript)
        }
    }

    func stop() {
        wantsRecording = false
        recognitionRequest?.endAudio()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
        level = 0
    }

    /// RMS level of a capture buffer, normalized/shaped to 0…1 to match the
    /// app's other input meters.
    private static func meterLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0 ..< count {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        return min(1, pow(min(1, rms * 8), 0.65))
    }

    private func start(baseText: String, onTranscript: @escaping (String) -> Void) {
        errorMessage = nil
        self.baseText = baseText
        self.onTranscript = onTranscript
        wantsRecording = true

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, self.wantsRecording else {
                    return
                }
                guard status == .authorized else {
                    self.errorMessage = "Speech recognition permission was declined. Enable it in System Settings > Privacy & Security."
                    return
                }
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard granted else {
                    self.errorMessage = "Microphone permission was declined. Enable it in System Settings > Privacy & Security."
                    return
                }
                guard self.wantsRecording else {
                    return
                }
                self.beginRecognition()
            }
        }
    }

    private func beginRecognition() {
        guard !isRecording else {
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            errorMessage = "Speech recognition is unavailable on this Mac."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = ChatDictationController.meterLevel(from: buffer)
            Task { @MainActor [weak self] in self?.level = level }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            recognitionRequest = nil
            errorMessage = "Could not start the microphone: \(error.localizedDescription)"
            return
        }

        isRecording = true
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                if let result {
                    self.emit(result.bestTranscription.formattedString)
                    if result.isFinal {
                        self.stop()
                    }
                }
                if error != nil, self.isRecording {
                    self.stop()
                }
            }
        }
    }

    private func emit(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return
        }
        let prefix = baseText.isEmpty || baseText.hasSuffix(" ")
            ? baseText
            : baseText + " "
        onTranscript?(prefix + trimmed)
    }
}
