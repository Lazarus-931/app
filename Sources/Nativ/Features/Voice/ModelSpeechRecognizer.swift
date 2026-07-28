import AVFoundation
import Foundation
import NativServerKit

@MainActor
final class ModelSpeechRecognizer: ObservableObject {
    @Published private(set) var level: Double = 0
    @Published var errorMessage: String?

    var onUtterance: ((String) -> Void)?

    var model: String?
    var apiKey: String?
    var baseURL = URL(string: "http://127.0.0.1:8081")!

    private let audioEngine = AVAudioEngine()
    private let samples = RecordedSampleBuffer()
    private var silenceTimer: Timer?
    private var isListening = false
    private var isRunning = false
    private var hasSpoken = false
    private var sampleRate: Double = 16_000

    private var peakLevel: Double = 0.05
    private let noiseFloor: Double = 0.006
    private let speechThreshold: Double = 0.02
    private let endOfTurnSilence: TimeInterval = 1.3

    func start() {
        guard !isListening else {
            return
        }
        isRunning = true
        errorMessage = nil
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else {
                return
            }
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard self.isRunning else {
                return
            }
            guard granted else {
                self.errorMessage = "Microphone permission was declined. Enable it in System Settings › Privacy & Security."
                return
            }
            self.beginCycle()
        }
    }

    func stop() {
        isRunning = false
        endCycle()
        level = 0
    }

    private func beginCycle() {
        guard !isListening else {
            return
        }
        hasSpoken = false
        samples.reset()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        let samples = samples
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            samples.append(buffer)
            let rms = RecordedSampleBuffer.rms(buffer)
            Task { @MainActor [weak self] in
                self?.updateLevel(rms)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            errorMessage = "Could not start the microphone: \(error.localizedDescription)"
            return
        }
        isListening = true
    }

    private func updateLevel(_ rms: Float) {
        let x = Double(rms)
        peakLevel = max(x, peakLevel * 0.997)
        let span = max(peakLevel - noiseFloor, 0.02)
        let norm = min(1.0, max(0.0, (x - noiseFloor) / span))
        level = level * 0.4 + pow(norm, 0.7) * 0.6

        if x > speechThreshold {
            hasSpoken = true
            silenceTimer?.invalidate()
            silenceTimer = nil
        } else if hasSpoken, silenceTimer == nil {
            scheduleEndOfTurn()
        }
    }

    private func scheduleEndOfTurn() {
        let timer = Timer(timeInterval: endOfTurnSilence, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishTurn()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    private func finishTurn() {
        guard isListening else {
            return
        }
        let spoke = hasSpoken
        let wav = samples.makeWAV(sampleRate: sampleRate)
        endCycle()
        level = 0
        guard spoke, let model, !wav.isEmpty else {
            return
        }
        let baseURL = baseURL
        let apiKey = apiKey
        Task { [weak self] in
            let client = NativAudioClient(baseURL: baseURL, apiKey: apiKey)
            let text = try? await client.transcribe(wav, fileName: "speech.wav", model: model)
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            await MainActor.run { [weak self] in
                guard let self, self.isRunning, !trimmed.isEmpty else {
                    return
                }
                self.onUtterance?(trimmed)
            }
        }
    }

    private func endCycle() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        isListening = false
        hasSpoken = false
    }
}

private final class RecordedSampleBuffer: @unchecked Sendable {
    private var storage = [Int16]()
    private let lock = NSLock()

    func reset() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else {
            return
        }
        var chunk = [Int16]()
        chunk.reserveCapacity(frames)
        if let floatData = buffer.floatChannelData {
            let channels = Int(buffer.format.channelCount)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += floatData[channel][frame]
                }
                let mono = max(-1, min(1, sum / Float(channels)))
                chunk.append(Int16(mono * Float(Int16.max)))
            }
        } else if let intData = buffer.int16ChannelData {
            for frame in 0..<frames {
                chunk.append(intData[0][frame])
            }
        }
        lock.lock()
        storage.append(contentsOf: chunk)
        lock.unlock()
    }

    func makeWAV(sampleRate: Double) -> Data {
        lock.lock()
        let samples = storage
        lock.unlock()
        return Self.wav(samples: samples, sampleRate: Int(sampleRate))
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0, let channel = buffer.floatChannelData?[0] else {
            return 0
        }
        var sum: Float = 0
        for index in 0..<count {
            sum += channel[index] * channel[index]
        }
        return (sum / Float(count)).squareRoot()
    }

    static func wav(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        let dataSize = samples.count * 2
        let byteRate = sampleRate * 2
        func appendString(_ value: String) {
            data.append(contentsOf: Array(value.utf8))
        }
        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        appendString("RIFF")
        appendUInt32(UInt32(36 + dataSize))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(2)
        appendUInt16(16)
        appendString("data")
        appendUInt32(UInt32(dataSize))
        for sample in samples {
            appendUInt16(UInt16(bitPattern: sample))
        }
        return data
    }
}
