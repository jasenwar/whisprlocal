@preconcurrency import AVFoundation
import Foundation

@MainActor
final class AudioCaptureService {
    private var engine: AVAudioEngine?
    private let accumulator = AudioSampleAccumulator()
    private(set) var isRecording = false

    func start() throws {
        guard !isRecording else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw WhisprLocalError.microphoneDenied
        }

        accumulator.reset(sampleRate: format.sampleRate)
        let tapHandler = AudioTapHandler(accumulator: accumulator)

        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format,
            block: tapHandler.receive
        )

        engine.prepare()
        do {
            try engine.start()
            self.engine = engine
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() -> [Float] {
        guard isRecording, let engine else { return [] }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        isRecording = false
        let captured = accumulator.snapshot()
        return Self.resample(
            captured.samples,
            from: captured.sampleRate,
            to: 16_000
        )
    }

    func cancel() {
        guard isRecording, let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        isRecording = false
        accumulator.clear()
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

final class AudioTapHandler: @unchecked Sendable {
    private let accumulator: AudioSampleAccumulator

    init(accumulator: AudioSampleAccumulator) {
        self.accumulator = accumulator
    }

    func receive(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        guard let channels = buffer.floatChannelData else { return }
        accumulator.append(
            UnsafeBufferPointer(
                start: channels[0],
                count: Int(buffer.frameLength)
            )
        )
    }
}

struct AudioSampleSnapshot: Sendable {
    let samples: [Float]
    let sampleRate: Double
}

final class AudioSampleAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 16_000

    func reset(sampleRate: Double) {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            self.sampleRate = sampleRate
        }
    }

    func append(_ input: UnsafeBufferPointer<Float>) {
        lock.withLock {
            samples.append(contentsOf: input)
        }
    }

    func snapshot() -> AudioSampleSnapshot {
        lock.withLock {
            AudioSampleSnapshot(samples: samples, sampleRate: sampleRate)
        }
    }

    func clear() {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
        }
    }
}
