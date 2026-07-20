import AVFoundation
import Speech
import SwiftUI

@MainActor
final class ChatDictationController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var baseText = ""
    private var onTranscript: ((String) -> Void)?

    func toggle(baseText: String, onTranscript: @escaping (String) -> Void) {
        if isRecording {
            stop()
        } else {
            start(baseText: baseText, onTranscript: onTranscript)
        }
    }

    func stop() {
        recognitionRequest?.endAudio()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
    }

    private func start(baseText: String, onTranscript: @escaping (String) -> Void) {
        errorMessage = nil
        self.baseText = baseText
        self.onTranscript = onTranscript

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else {
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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
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
