@preconcurrency import AVFoundation
import Foundation
import OSLog

private let audioCaptureLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "AudioCapture"
)

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
            audioCaptureLogger.error(
                "Input format unavailable: rate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)"
            )
            throw WhisprLocalError.microphoneDenied
        }

        let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName
            ?? "Unknown default input"
        audioCaptureLogger.info(
            "Starting capture: device=\(deviceName, privacy: .public) rate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public) format=\(String(describing: format.commonFormat), privacy: .public) interleaved=\(format.isInterleaved, privacy: .public)"
        )
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
            audioCaptureLogger.info("Capture engine started")
        } catch {
            input.removeTap(onBus: 0)
            audioCaptureLogger.error(
                "Capture engine failed to start: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    func stop() -> [Float] {
        guard isRecording, let engine else {
            audioCaptureLogger.error(
                "Stop requested before capture engine was recording"
            )
            return []
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        isRecording = false
        let captured = accumulator.snapshot()
        let resampled = Self.resample(
            captured.samples,
            from: captured.sampleRate,
            to: 16_000
        )
        let metrics = AudioSignalMetrics(samples: resampled)
        audioCaptureLogger.info(
            "Capture stopped: sourceSamples=\(captured.samples.count, privacy: .public) sourceRate=\(captured.sampleRate, privacy: .public) outputSamples=\(resampled.count, privacy: .public) duration=\(metrics.duration(sampleRate: 16_000), format: .fixed(precision: 3), privacy: .public)s rms=\(metrics.rms, format: .fixed(precision: 6), privacy: .public) peak=\(metrics.peak, format: .fixed(precision: 6), privacy: .public) activePercent=\(metrics.activeFraction * 100, format: .fixed(precision: 2), privacy: .public)"
        )
        return resampled
    }

    func cancel() {
        guard isRecording, let engine else {
            audioCaptureLogger.info(
                "Cancel requested with no active capture engine"
            )
            return
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        isRecording = false
        accumulator.clear()
        audioCaptureLogger.info("Capture cancelled and samples discarded")
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

struct AudioSignalMetrics: Sendable {
    let sampleCount: Int
    let rms: Double
    let peak: Double
    let activeFraction: Double

    init(samples: [Float], activeThreshold: Float = 0.001) {
        sampleCount = samples.count
        guard !samples.isEmpty else {
            rms = 0
            peak = 0
            activeFraction = 0
            return
        }

        var sumOfSquares = 0.0
        var peak = 0.0
        var activeSamples = 0
        for sample in samples where sample.isFinite {
            let magnitude = Double(abs(sample))
            sumOfSquares += magnitude * magnitude
            peak = max(peak, magnitude)
            if magnitude >= Double(activeThreshold) {
                activeSamples += 1
            }
        }

        rms = sqrt(sumOfSquares / Double(samples.count))
        self.peak = peak
        activeFraction = Double(activeSamples) / Double(samples.count)
    }

    func duration(sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 0 }
        return Double(sampleCount) / sampleRate
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
