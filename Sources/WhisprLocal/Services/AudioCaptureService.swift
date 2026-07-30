@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

private let audioCaptureLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "AudioCapture"
)

protocol AudioCapturing: Sendable {
    func start(mode: MicrophoneMode) async throws -> AudioCaptureStartInfo
    func stop() async -> [Float]
    func cancel() async
}

struct AudioCaptureStartInfo: Equatable, Sendable {
    let deviceName: String
    let sampleRate: Double
}

actor AudioCaptureService: AudioCapturing {
    private static let maximumStartAttempts = 2
    private static let firstBufferTimeout: Duration = .milliseconds(500)

    private var engine: AVAudioEngine?
    private var recordingGeneration: UUID?
    private let accumulator = AudioSampleAccumulator()

    func start(mode: MicrophoneMode) async throws -> AudioCaptureStartInfo {
        if let engine, engine.isRunning,
           let deviceName = AudioInputDeviceResolver.inputDevice(for: mode)?.name {
            return AudioCaptureStartInfo(
                deviceName: deviceName,
                sampleRate: accumulator.snapshot().sampleRate
            )
        }

        let overallStarted = ContinuousClock.now
        var lastError: Error = WhisprLocalError.microphoneUnavailable

        for attempt in 1...Self.maximumStartAttempts {
            try Task.checkCancellation()
            let generation = UUID()

            do {
                let prepared = try prepareEngine(
                    mode: mode,
                    generation: generation,
                    attempt: attempt
                )
                engine = prepared.engine
                recordingGeneration = generation

                try prepared.engine.start()
                try Task.checkCancellation()

                let receivedBuffer = await prepared.readiness.wait(
                    timeout: Self.firstBufferTimeout
                )
                try Task.checkCancellation()
                guard recordingGeneration == generation else {
                    throw CancellationError()
                }
                guard receivedBuffer else {
                    throw WhisprLocalError.microphoneUnavailable
                }

                let elapsed = (ContinuousClock.now - overallStarted).timeInterval
                audioCaptureLogger.info(
                    "Capture ready: device=\(prepared.info.deviceName, privacy: .public) attempt=\(attempt, privacy: .public) startupSeconds=\(elapsed, format: .fixed(precision: 3), privacy: .public)"
                )
                return prepared.info
            } catch is CancellationError {
                tearDownEngine(for: generation, clearSamples: true)
                audioCaptureLogger.info(
                    "Capture preparation cancelled on attempt=\(attempt, privacy: .public)"
                )
                throw CancellationError()
            } catch {
                lastError = error
                tearDownEngine(for: generation, clearSamples: true)
                audioCaptureLogger.error(
                    "Capture attempt=\(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                guard attempt < Self.maximumStartAttempts else { break }
                try await Task.sleep(for: .milliseconds(80))
            }
        }

        audioCaptureLogger.error(
            "Microphone failed after \(Self.maximumStartAttempts, privacy: .public) attempts: \(lastError.localizedDescription, privacy: .public)"
        )
        throw WhisprLocalError.microphoneUnavailable
    }

    func stop() -> [Float] {
        guard let engine, let generation = recordingGeneration else {
            audioCaptureLogger.error(
                "Stop requested before capture became ready"
            )
            return []
        }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        recordingGeneration = nil

        let captured = accumulator.snapshot()
        let resampled = Self.resample(
            captured.samples,
            from: captured.sampleRate,
            to: 16_000
        )
        let metrics = AudioSignalMetrics(samples: resampled)
        audioCaptureLogger.info(
            "Capture stopped: generation=\(generation.uuidString, privacy: .private(mask: .hash)) sourceSamples=\(captured.samples.count, privacy: .public) sourceRate=\(captured.sampleRate, privacy: .public) outputSamples=\(resampled.count, privacy: .public) duration=\(metrics.duration(sampleRate: 16_000), format: .fixed(precision: 3), privacy: .public)s rms=\(metrics.rms, format: .fixed(precision: 6), privacy: .public) peak=\(metrics.peak, format: .fixed(precision: 6), privacy: .public) activePercent=\(metrics.activeFraction * 100, format: .fixed(precision: 2), privacy: .public)"
        )
        return resampled
    }

    func cancel() {
        guard let generation = recordingGeneration else {
            accumulator.clear()
            audioCaptureLogger.info(
                "Cancel requested with no prepared capture engine"
            )
            return
        }
        tearDownEngine(for: generation, clearSamples: true)
        audioCaptureLogger.info("Capture cancelled and samples discarded")
    }

    private func prepareEngine(
        mode: MicrophoneMode,
        generation: UUID,
        attempt: Int
    ) throws -> (
        engine: AVAudioEngine,
        readiness: AudioCaptureReadinessGate,
        info: AudioCaptureStartInfo
    ) {
        guard let device = AudioInputDeviceResolver.inputDevice(for: mode) else {
            throw WhisprLocalError.microphoneUnavailable
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if mode == .builtIn {
            try Self.select(device: device, for: input)
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            audioCaptureLogger.error(
                "Input format unavailable: rate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)"
            )
            throw WhisprLocalError.microphoneUnavailable
        }

        audioCaptureLogger.info(
            "Preparing capture: mode=\(mode.rawValue, privacy: .public) device=\(device.name, privacy: .public) attempt=\(attempt, privacy: .public) rate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public) format=\(String(describing: format.commonFormat), privacy: .public) interleaved=\(format.isInterleaved, privacy: .public)"
        )
        accumulator.reset(sampleRate: format.sampleRate)
        let readiness = AudioCaptureReadinessGate()
        let tapHandler = AudioTapHandler(
            accumulator: accumulator,
            readiness: readiness
        )
        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format,
            block: tapHandler.receive
        )
        engine.prepare()

        return (
            engine,
            readiness,
            AudioCaptureStartInfo(
                deviceName: device.name,
                sampleRate: format.sampleRate
            )
        )
    }

    private static func select(
        device: AudioInputDevice,
        for input: AVAudioInputNode
    ) throws {
        guard let audioUnit = input.audioUnit else {
            throw WhisprLocalError.microphoneUnavailable
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            audioCaptureLogger.error(
                "Could not select built-in input device status=\(status, privacy: .public)"
            )
            throw WhisprLocalError.microphoneUnavailable
        }
    }

    private func tearDownEngine(
        for generation: UUID,
        clearSamples: Bool
    ) {
        guard recordingGeneration == generation else { return }
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        recordingGeneration = nil
        if clearSamples {
            accumulator.clear()
        }
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

struct AudioInputDevice: Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
    let transportType: UInt32
}

enum AudioInputDeviceResolver {
    static func inputDevice(for mode: MicrophoneMode) -> AudioInputDevice? {
        switch mode {
        case .systemDefault:
            guard let id = defaultInputDeviceID() else { return nil }
            return device(for: id)
        case .builtIn:
            return allInputDevices().first {
                $0.transportType == kAudioDeviceTransportTypeBuiltIn
            }
        }
    }

    static func defaultInputDeviceName() -> String? {
        inputDevice(for: .systemDefault)?.name
    }

    static func builtInInputDeviceName() -> String? {
        inputDevice(for: .builtIn)?.name
    }

    static func allInputDevices() -> [AudioInputDevice] {
        allDeviceIDs()
            .filter { inputChannelCount(for: $0) > 0 }
            .compactMap(device(for:))
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }

        var devices = Array(
            repeating: AudioDeviceID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devices
        ) == noErr else {
            return []
        }
        return devices.filter { $0 != kAudioObjectUnknown }
    }

    private static func device(
        for id: AudioDeviceID
    ) -> AudioInputDevice? {
        guard let name = stringProperty(
            kAudioObjectPropertyName,
            for: id
        ) else {
            return nil
        }
        return AudioInputDevice(
            id: id,
            name: name,
            transportType: uint32Property(
                kAudioDevicePropertyTransportType,
                for: id
            ) ?? 0
        )
    }

    private static func inputChannelCount(
        for id: AudioDeviceID
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            id,
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else {
            return 0
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(
            id,
            &address,
            0,
            nil,
            &size,
            storage
        ) == noErr else {
            return 0
        }

        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    private static func uint32Property(
        _ selector: AudioObjectPropertySelector,
        for objectID: AudioObjectID
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr ? value : nil
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        for objectID: AudioObjectID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
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
    private let readiness: AudioCaptureReadinessGate?

    init(
        accumulator: AudioSampleAccumulator,
        readiness: AudioCaptureReadinessGate? = nil
    ) {
        self.accumulator = accumulator
        self.readiness = readiness
    }

    func receive(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else {
            return
        }
        accumulator.append(
            UnsafeBufferPointer(
                start: channels[0],
                count: Int(buffer.frameLength)
            )
        )
        readiness?.signal()
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

final class AudioCaptureReadinessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func signal() {
        resolve(true)
    }

    func wait(timeout: Duration) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediateResult = lock.withLock { () -> Bool? in
                    if let result {
                        return result
                    }
                    self.continuation = continuation
                    return nil
                }
                if let immediateResult {
                    continuation.resume(returning: immediateResult)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + timeout.timeInterval
                ) { [weak self] in
                    self?.resolve(false)
                }
            }
        } onCancel: {
            resolve(false)
        }
    }

    private func resolve(_ result: Bool) {
        let continuation: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}
