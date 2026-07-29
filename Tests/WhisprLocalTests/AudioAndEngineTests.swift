import XCTest
@testable import WhisprLocal

final class AudioAndEngineTests: XCTestCase {
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
