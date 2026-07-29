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
            hotwords: ["Jasen Guerra"]
        )
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertTrue(result.engine.contains("Parakeet Unified English"))
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
