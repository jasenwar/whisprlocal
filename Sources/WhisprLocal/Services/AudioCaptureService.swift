@preconcurrency import AVFoundation
import Foundation

@MainActor
final class AudioCaptureService {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sourceSampleRate: Double = 16_000
    private(set) var isRecording = false

    func start() throws {
        guard !isRecording else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw WhisprLocalError.microphoneDenied
        }

        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            sourceSampleRate = format.sampleRate
        }

        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format
        ) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let channel = channels[0]
            self.lock.withLock {
                self.samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
            }
        }

        engine.prepare()
        do {
            try engine.start()
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
        let captured = lock.withLock { samples }
        return Self.resample(captured, from: sourceSampleRate, to: 16_000)
    }

    func cancel() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
        lock.withLock { samples.removeAll() }
    }

    nonisolated static func resample(
        _ input: [Float],
        from sourceRate: Double,
        to targetRate: Double
    ) -> [Float] {
        guard !input.isEmpty, sourceRate > 0, targetRate > 0 else { return [] }
        if abs(sourceRate - targetRate) < 1 { return input }
        let outputCount = Int(Double(input.count) * targetRate / sourceRate)
        guard outputCount > 0 else { return [] }
        let scale = sourceRate / targetRate
        return (0..<outputCount).map { index in
            let sourcePosition = Double(index) * scale
            let lower = min(Int(sourcePosition), input.count - 1)
            let upper = min(lower + 1, input.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            return input[lower] * (1 - fraction) + input[upper] * fraction
        }
    }
}
