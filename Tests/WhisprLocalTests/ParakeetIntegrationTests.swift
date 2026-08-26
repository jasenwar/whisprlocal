import AVFoundation
import XCTest
@testable import WhisprLocal

@MainActor
final class ParakeetIntegrationTests: XCTestCase {
    func testFixedEnglishFixtureTranscribesWithPerStreamHotwords() async throws {
        let manager = ModelManager()
        guard try await manager.prepareFromExistingCache() else {
            throw XCTSkip("Parakeet cache is not available for the integration test.")
        }
        let (samples, sampleRate) = try loadFixture()
        let engine = ParakeetTranscriptionEngine(modelManager: manager)
        let result = try await engine.transcribe(
            samples: samples,
            sampleRate: sampleRate,
            hotwordPhrases: [HotwordPhrase("Phoebe", score: 2.0)]
        )
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertTrue(result.engine.contains("Parakeet Unified English"))
        XCTAssertTrue(
            result.text.localizedCaseInsensitiveContains("Phoebe"),
            "Expected the fixed custom-term fixture to contain Phoebe."
        )
    }

    func testShortQuietEnglishFixtureStillTranscribes() async throws {
        let manager = ModelManager()
        guard try await manager.prepareFromExistingCache() else {
            throw XCTSkip("Parakeet cache is not available for the integration test.")
        }
        let (samples, sampleRate) = try loadFixture()
        let speechStart = Int(Double(sampleRate) * 0.55)
        let speechEnd = Int(Double(sampleRate) * 2.50)
        let shortPhrase = Array(samples[speechStart..<speechEnd])
        let originalMetrics = AudioSignalMetrics(samples: shortPhrase)
        let targetRMS = 0.0045
        let quietScale = targetRMS / originalMetrics.rms
        let quietSamples = shortPhrase.map { $0 * Float(quietScale) }
        let metrics = AudioSignalMetrics(samples: quietSamples)
        XCTAssertGreaterThan(metrics.rms, 0.0008)
        XCTAssertEqual(metrics.rms, targetRMS, accuracy: 0.0001)

        let engine = ParakeetTranscriptionEngine(modelManager: manager)
        let result = try await engine.transcribe(
            samples: quietSamples,
            sampleRate: sampleRate,
            hotwords: ["Jasen Guerra"]
        )
        XCTAssertFalse(result.text.isEmpty)
    }

    func testNon16KSampleRateIsRejectedBeforeModelLoading() async {
        let manager = ModelManager(
            baseDirectory: FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        )
        let engine = ParakeetTranscriptionEngine(modelManager: manager)

        do {
            _ = try await engine.transcribe(
                samples: Array(repeating: 0.2, count: 9_600),
                sampleRate: 48_000,
                hotwords: []
            )
            XCTFail("Expected a non-16 kHz sample-rate error.")
        } catch WhisprLocalError.transcriptionFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func loadFixture() throws -> (samples: [Float], sampleRate: Int) {
        let fixture = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "parakeet-english",
                withExtension: "wav"
            ),
            "Missing fixed WAV fixture."
        )
        let file = try AVAudioFile(forReading: fixture)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw FixtureError.couldNotAllocateBuffer
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw FixtureError.notFloatingPointPCM
        }
        let samples = Array(
            UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        )
        return (samples, Int(file.processingFormat.sampleRate))
    }
}

private enum FixtureError: Error {
    case couldNotAllocateBuffer
    case notFloatingPointPCM
}
