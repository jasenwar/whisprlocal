@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

private let audioCaptureLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "AudioCapture"
)

@MainActor
protocol AudioCapturing: AnyObject {
    var isRecording: Bool { get }
    var selectedInputDeviceName: String? { get }

    func start(inputMode: AudioInputMode) throws
    func stop() -> [Float]
    func cancel()
}

@MainActor
final class AudioCaptureService: AudioCapturing {
    private var engine: AVAudioEngine?
    private let accumulator = AudioSampleAccumulator()
    private(set) var isRecording = false
    private(set) var selectedInputDeviceName: String?

    func start(inputMode: AudioInputMode) throws {
        guard !isRecording else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let selectedDevice = selectInputDevice(
            for: inputMode,
            inputNode: input
        )
        selectedInputDeviceName = selectedDevice.name
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            audioCaptureLogger.error(
                "Input format unavailable: rate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)"
            )
            throw WhisprLocalError.microphoneDenied
        }

        audioCaptureLogger.info(
            "Starting capture: mode=\(inputMode.rawValue, privacy: .public) device=\(selectedDevice.name, privacy: .public) rate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public) format=\(String(describing: format.commonFormat), privacy: .public) interleaved=\(format.isInterleaved, privacy: .public)"
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

    private func selectInputDevice(
        for inputMode: AudioInputMode,
        inputNode: AVAudioInputNode
    ) -> AudioInputDeviceDescriptor {
        if inputMode == .fastStart {
            if let builtInDevice = AudioInputDeviceResolver.builtInInputDevice(),
               let audioUnit = inputNode.audioUnit {
                var deviceID = builtInDevice.id
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status == noErr {
                    return builtInDevice
                }
                audioCaptureLogger.error(
                    "Built-in microphone selection failed with OSStatus \(status, privacy: .public); using system default"
                )
            } else {
                audioCaptureLogger.error(
                    "No built-in microphone was available; using system default"
                )
            }
        }

        return AudioInputDeviceResolver.defaultInputDevice()
            ?? AudioInputDeviceDescriptor(
                id: kAudioObjectUnknown,
                name: AVCaptureDevice.default(for: .audio)?.localizedName
                    ?? "Unknown default input",
                transportType: 0
            )
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

struct AudioInputDeviceDescriptor: Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
    let transportType: UInt32
}

enum AudioInputDeviceResolver {
    static func builtInInputDevice() -> AudioInputDeviceDescriptor? {
        preferredBuiltInInputDevice(from: inputDevices())
    }

    static func defaultInputDevice() -> AudioInputDeviceDescriptor? {
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
        return descriptor(for: deviceID)
    }

    static func preferredBuiltInInputDevice(
        from devices: [AudioInputDeviceDescriptor]
    ) -> AudioInputDeviceDescriptor? {
        let builtIn = devices.filter {
            $0.transportType == kAudioDeviceTransportTypeBuiltIn
        }
        return builtIn.first {
            $0.name.localizedCaseInsensitiveContains("microphone")
        } ?? builtIn.first
    }

    private static func inputDevices() -> [AudioInputDeviceDescriptor] {
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

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let status = deviceIDs.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                buffer.baseAddress!
            )
        }
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard hasInputStreams(deviceID) else { return nil }
            return descriptor(for: deviceID)
        }
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        ) == noErr && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func descriptor(
        for deviceID: AudioDeviceID
    ) -> AudioInputDeviceDescriptor? {
        guard let name = stringProperty(
            kAudioObjectPropertyName,
            for: deviceID
        ) else {
            return nil
        }
        let transportType = uint32Property(
            kAudioDevicePropertyTransportType,
            for: deviceID
        ) ?? 0
        return AudioInputDeviceDescriptor(
            id: deviceID,
            name: name,
            transportType: transportType
        )
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
