import AVFoundation
import Foundation

/// Plays TTS audio bytes and exposes a smoothed output level (0...1) that drives
/// the voice orb while the model is speaking.
@MainActor
final class VoiceAudioPlayer: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var level: Double = 0

    private var player: AVAudioPlayer?
    private var meterTimer: Timer?
    private var completion: (() -> Void)?
    /// Auto-gain: decaying running peak of the playback amplitude.
    private var peakLevel: Double = 0.2

    /// Play the given audio data. `onFinish` fires when playback completes naturally
    /// (not when `stop()` is called).
    func play(_ data: Data, onFinish: (() -> Void)? = nil) throws {
        stop()
        let player = try AVAudioPlayer(data: data)
        player.isMeteringEnabled = true
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        self.completion = onFinish
        player.play()
        isPlaying = true
        startMetering()
    }

    func stop() {
        meterTimer?.invalidate()
        meterTimer = nil
        completion = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        isPlaying = false
        level = 0
    }

    private func startMetering() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateLevel()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func updateLevel() {
        guard let player, player.isPlaying else {
            return
        }
        player.updateMeters()
        let power = player.averagePower(forChannel: 0)
        let amplitude = pow(10.0, Double(power) / 20.0)
        // Auto-gain: normalize against a decaying running peak so the model's speech
        // spans the orb's full range regardless of TTS loudness.
        peakLevel = max(amplitude, peakLevel * 0.995)
        let span = max(peakLevel - 0.01, 0.05)
        let norm = min(1.0, max(0.0, (amplitude - 0.01) / span))
        let scaled = pow(norm, 0.7)
        level = level * 0.5 + scaled * 0.5
    }
}

extension VoiceAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let onFinish = self.completion
            self.meterTimer?.invalidate()
            self.meterTimer = nil
            self.completion = nil
            self.player = nil
            self.isPlaying = false
            self.level = 0
            onFinish?()
        }
    }
}
