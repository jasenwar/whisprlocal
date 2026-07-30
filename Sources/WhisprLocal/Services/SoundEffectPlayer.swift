@preconcurrency import AVFoundation
import OSLog

private let soundEffectLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "SoundEffects"
)

@MainActor
final class SoundEffectPlayer {
    private static let startNotes = [523.25, 659.25]
    private static let stopNotes = [587.33, 440.0]
    private static let sampleRate = 48_000.0
    private static let noteDuration = 0.09
    private static let noteGap = 0.025
    private static let noteAttack = 0.015
    private static let maximumGain: Float = 0.2
    private static let minimumGain: Float = 0.0001

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let startBuffer: AVAudioPCMBuffer
    private let stopBuffer: AVAudioPCMBuffer

    init?() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let startBuffer = Self.makeCueBuffer(
            notes: Self.startNotes,
            format: format
        ),
        let stopBuffer = Self.makeCueBuffer(
            notes: Self.stopNotes,
            format: format
        ) else {
            soundEffectLogger.error("Could not create OpenWhispr cue buffers")
            return nil
        }

        self.format = format
        self.startBuffer = startBuffer
        self.stopBuffer = stopBuffer
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    func playStartCue() {
        play(buffer: startBuffer, name: "OpenWhispr start")
    }

    func playStopCue() {
        play(buffer: stopBuffer, name: "OpenWhispr stop")
    }

    var isReady: Bool {
        engine.isRunning
    }

    var isPlaying: Bool {
        player.isPlaying
    }

    static func makeCueSamples(
        notes: [Double],
        sampleRate: Double = sampleRate
    ) -> [Float] {
        guard !notes.isEmpty, sampleRate > 0 else { return [] }
        let noteFrames = Int((noteDuration * sampleRate).rounded())
        let gapFrames = Int((noteGap * sampleRate).rounded())
        let attackFrames = max(1, Int((noteAttack * sampleRate).rounded()))
        let totalFrames = noteFrames * notes.count
            + gapFrames * max(0, notes.count - 1)
        var samples = [Float](repeating: 0, count: totalFrames)

        for (noteIndex, frequency) in notes.enumerated() {
            let noteStart = noteIndex * (noteFrames + gapFrames)
            for frame in 0..<noteFrames {
                let time = Double(frame) / sampleRate
                let gain: Float
                if frame < attackFrames {
                    let progress = Float(frame) / Float(attackFrames)
                    gain = minimumGain
                        + (maximumGain - minimumGain) * progress
                } else {
                    let decayFrames = max(1, noteFrames - attackFrames)
                    let progress = Float(frame - attackFrames)
                        / Float(decayFrames)
                    gain = maximumGain
                        * pow(minimumGain / maximumGain, progress)
                }
                samples[noteStart + frame] = gain
                    * Float(sin(2 * Double.pi * frequency * time))
            }
        }
        return samples
    }

    private static func makeCueBuffer(
        notes: [Double],
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let samples = makeCueSamples(
            notes: notes,
            sampleRate: format.sampleRate
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ),
        let channel = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    private func play(buffer: AVAudioPCMBuffer, name: String) {
        let started = ContinuousClock.now
        player.stop()
        engine.stop()
        engine.reset()
        engine.prepare()
        guard startEngineIfNeeded() else { return }
        player.scheduleBuffer(buffer, at: nil)
        player.play()
        let acceptanceDelay = (
            ContinuousClock.now - started
        ).timeInterval
        soundEffectLogger.info(
            "Played \(name, privacy: .public) cue acceptanceDelay=\(acceptanceDelay, format: .fixed(precision: 3), privacy: .public)s"
        )
    }

    @discardableResult
    private func startEngineIfNeeded() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            soundEffectLogger.info(
                "OpenWhispr cue engine started"
            )
            return true
        } catch {
            soundEffectLogger.error(
                "OpenWhispr cue engine failed to start: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
