@preconcurrency import AVFoundation
import XCTest
@testable import WhisprLocal

final class AudioAndEngineTests: XCTestCase {
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
