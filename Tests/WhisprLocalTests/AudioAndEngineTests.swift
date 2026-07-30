@preconcurrency import AVFoundation
import CoreAudio
import XCTest
@testable import WhisprLocal

final class AudioAndEngineTests: XCTestCase {
    func testCaptureUsesSystemDefaultMicrophone() async throws {
        let service = AudioCaptureService()
        let expectedDevice = try XCTUnwrap(
            AudioInputDeviceResolver.defaultInputDeviceName()
        )
        let info = try await service.start(mode: .systemDefault)
        await service.cancel()

        XCTAssertEqual(info.deviceName, expectedDevice)
        XCTAssertGreaterThan(info.sampleRate, 0)
    }

    func testBuiltInMicrophoneCanBeResolvedWithoutChangingSystemDefault() {
        let device = AudioInputDeviceResolver.inputDevice(for: .builtIn)

        XCTAssertNotNil(device)
        XCTAssertEqual(
            device?.transportType,
            kAudioDeviceTransportTypeBuiltIn
        )
    }

    func testCaptureCanUseBuiltInMicrophone() async throws {
        let service = AudioCaptureService()
        let expectedDevice = try XCTUnwrap(
            AudioInputDeviceResolver.builtInInputDeviceName()
        )

        let info = try await service.start(mode: .builtIn)
        await service.cancel()

        XCTAssertEqual(info.deviceName, expectedDevice)
        XCTAssertGreaterThan(info.sampleRate, 0)
    }

    func testAudioSignalMetricsDescribeAudibleSamples() {
        let samples: [Float] = [0, 0.001, -0.002, 0.004]
        let metrics = AudioSignalMetrics(samples: samples)

        XCTAssertEqual(metrics.sampleCount, 4)
        XCTAssertEqual(metrics.peak, 0.004, accuracy: 0.000_001)
        XCTAssertGreaterThan(metrics.rms, 0.002)
        XCTAssertEqual(metrics.activeFraction, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(metrics.duration(sampleRate: 4), 1)
    }

    func testBoundarySilencePadsBothSidesWithoutChangingSpeech() {
        let speech: [Float] = [0.25, -0.5]
        let padded = ParakeetTranscriptionEngine.addingBoundarySilence(
            to: speech,
            sampleRate: 10,
            duration: 0.2
        )

        XCTAssertEqual(padded, [0, 0, 0.25, -0.5, 0, 0])
    }

    @MainActor
    func testOpenWhisprStartCueMatchesUpstreamTimingAndGain() {
        let samples = SoundEffectPlayer.makeCueSamples(
            notes: [523.25, 659.25],
            sampleRate: 48_000
        )

        XCTAssertEqual(samples.count, 9_840)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.18)
        XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 1, 0.2)
        XCTAssertTrue(samples[4_320..<5_520].allSatisfy { $0 == 0 })
    }

    @MainActor
    func testOpenWhisprCueEngineStartsOnlyWhenSoundIsPlayed() throws {
        let player = try XCTUnwrap(SoundEffectPlayer())
        XCTAssertFalse(player.isReady)

        player.playStartCue()

        XCTAssertTrue(player.isReady)
        XCTAssertTrue(player.isPlaying)
    }

    func testOpenWhisprStartCueSurvivesInputStartup() async throws {
        let cuePlayer = try await MainActor.run {
            try XCTUnwrap(SoundEffectPlayer())
        }
        let capture = AudioCaptureService()
        _ = try await capture.start(mode: .systemDefault)

        try await Task.sleep(for: .milliseconds(120))
        await MainActor.run {
            cuePlayer.playStartCue()
        }

        await MainActor.run {
            XCTAssertTrue(cuePlayer.isReady)
            XCTAssertTrue(cuePlayer.isPlaying)
        }
        await capture.cancel()
    }

    func testAudioTapHandlerAcceptsBufferOffMainActor() async throws {
        let accumulator = AudioSampleAccumulator()
        let expected = [Float](repeating: 0.25, count: 1_024)
        accumulator.reset(sampleRate: 48_000)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(expected.count)
            )
        )
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        expected.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: expected.count)
        }
        let sendableBuffer = SendableAudioBuffer(buffer)
        let handler = AudioTapHandler(accumulator: accumulator)

        await Task.detached {
            handler.receive(sendableBuffer.value, AVAudioTime())
        }.value

        let captured = accumulator.snapshot()
        XCTAssertEqual(captured.samples, expected)
        XCTAssertEqual(captured.sampleRate, 48_000)
    }

    func testCaptureReadinessWaitsForFirstBuffer() async {
        let gate = AudioCaptureReadinessGate()
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            gate.signal()
        }

        let ready = await gate.wait(timeout: .milliseconds(200))
        XCTAssertTrue(ready)
    }

    func testCaptureReadinessTimesOutWithoutBuffers() async {
        let gate = AudioCaptureReadinessGate()
        let started = ContinuousClock.now

        let ready = await gate.wait(timeout: .milliseconds(30))
        XCTAssertFalse(ready)
        XCTAssertLessThan(
            (ContinuousClock.now - started).timeInterval,
            0.25
        )
    }

    func testCaptureReadinessUnblocksWhenPreparationIsCancelled() async {
        let gate = AudioCaptureReadinessGate()
        let task = Task {
            await gate.wait(timeout: .seconds(1))
        }
        task.cancel()

        let ready = await task.value
        XCTAssertFalse(ready)
    }

    func testResamplingProducesExpectedLength() {
        let input = Array(repeating: Float(0.25), count: 48_000)
        let output = AudioCaptureService.resample(input, from: 48_000, to: 16_000)
        XCTAssertEqual(output.count, 16_000)
    }

    func testParakeetRejectsShortRecordingWithoutLoadingModel() async {
        let manager = ModelManager(baseDirectory: temporaryDirectory())
        let engine = ParakeetTranscriptionEngine(modelManager: manager)
        do {
            _ = try await engine.transcribe(
                samples: Array(repeating: 0.2, count: 1_000),
                sampleRate: 16_000,
                hotwords: []
            )
            XCTFail("Expected a short-recording error.")
        } catch WhisprLocalError.recordingTooShort {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testParakeetRejectsSilenceWithoutLoadingModel() async {
        let manager = ModelManager(baseDirectory: temporaryDirectory())
        let engine = ParakeetTranscriptionEngine(modelManager: manager)
        do {
            _ = try await engine.transcribe(
                samples: Array(repeating: 0, count: 16_000),
                sampleRate: 16_000,
                hotwords: []
            )
            XCTFail("Expected a no-speech error.")
        } catch WhisprLocalError.noSpeech {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }
}

private final class SendableAudioBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer

    init(_ value: AVAudioPCMBuffer) {
        self.value = value
    }
}
