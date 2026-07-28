import Foundation

/// Splits a growing stream of text into complete sentences so speech can start
/// before the model finishes writing. Holds back the trailing fragment until a
/// terminator followed by whitespace arrives (so "3.14" or "Dr." don't split).
struct SentenceChunker {
    private var buffer = ""

    mutating func push(_ text: String) -> [String] {
        buffer += text
        var sentences: [String] = []
        while let end = nextBoundary() {
            sentences.append(String(buffer[..<end]))
            buffer = String(buffer[end...])
        }
        return sentences
    }

    mutating func flush() -> String? {
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return tail.isEmpty ? nil : tail
    }

    private func nextBoundary() -> String.Index? {
        let terminators: Set<Character> = [".", "!", "?"]
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            if character == "\n" {
                return buffer.index(after: index)
            }
            if terminators.contains(character) {
                let after = buffer.index(after: index)
                if after == buffer.endIndex {
                    return nil
                }
                if buffer[after].isWhitespace {
                    return after
                }
            }
            index = buffer.index(after: index)
        }
        return nil
    }
}

/// Speaks a stream of sentences with no gaps: each sentence is synthesized as it
/// arrives and clips are played strictly in order, pre-synthesizing the next while
/// the current one plays. This is what makes the reply feel like natural speech
/// instead of waiting for the whole response before any audio.
@MainActor
final class VoiceSpeechQueue {
    var synthesize: ((String) async -> Data?)?
    var onSpeakingStarted: (() -> Void)?
    var onFinished: (() -> Void)?

    private let player: VoiceAudioPlayer
    private var pending: [String] = []
    private var ready: [Data] = []
    private var isSynthesizing = false
    private var isPlaying = false
    private var generationComplete = false
    private var isRunning = false
    private var hasStartedSpeaking = false

    init(player: VoiceAudioPlayer) {
        self.player = player
    }

    func begin() {
        isRunning = true
        generationComplete = false
        hasStartedSpeaking = false
        pending.removeAll()
        ready.removeAll()
        isSynthesizing = false
        isPlaying = false
    }

    func stop() {
        isRunning = false
        pending.removeAll()
        ready.removeAll()
        player.stop()
    }

    func enqueue(_ sentence: String) {
        guard isRunning else {
            return
        }
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        pending.append(trimmed)
        pumpSynthesis()
    }

    func finishGeneration() {
        generationComplete = true
        checkCompletion()
    }

    private func pumpSynthesis() {
        guard isRunning, !isSynthesizing, !pending.isEmpty, let synthesize else {
            return
        }
        isSynthesizing = true
        let sentence = pending.removeFirst()
        Task { [weak self] in
            let data = await synthesize(sentence)
            guard let self else {
                return
            }
            self.isSynthesizing = false
            if self.isRunning, let data {
                self.ready.append(data)
                self.pumpPlayback()
            }
            self.pumpSynthesis()
            self.checkCompletion()
        }
    }

    private func pumpPlayback() {
        guard isRunning, !isPlaying, !ready.isEmpty else {
            return
        }
        isPlaying = true
        if !hasStartedSpeaking {
            hasStartedSpeaking = true
            onSpeakingStarted?()
        }
        let clip = ready.removeFirst()
        do {
            try player.play(clip) { [weak self] in
                guard let self else {
                    return
                }
                self.isPlaying = false
                self.pumpPlayback()
                self.checkCompletion()
            }
        } catch {
            isPlaying = false
            pumpPlayback()
            checkCompletion()
        }
    }

    private func checkCompletion() {
        guard isRunning, generationComplete,
              pending.isEmpty, ready.isEmpty, !isSynthesizing, !isPlaying else {
            return
        }
        isRunning = false
        onFinished?()
    }
}
