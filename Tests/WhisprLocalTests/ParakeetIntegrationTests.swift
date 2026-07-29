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
        guard let fixture = Bundle(for: Self.self).url(
            forResource: "parakeet-english",
            withExtension: "wav"
        ) else {
            XCTFail("Missing fixed WAV fixture.")
            return
        }
        let file = try AVAudioFile(forReading: fixture)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            XCTFail("Could not allocate the fixture buffer.")
            return
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            XCTFail("The fixture is not floating-point PCM.")
            return
        }
        let samples = Array(
            UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        )
        let engine = ParakeetTranscriptionEngine(modelManager: manager)
        let result = try await engine.transcribe(
            samples: samples,
            sampleRate: Int(file.processingFormat.sampleRate),
            hotwords: ["Jasen Guerra"]
        )
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertTrue(result.engine.contains("Parakeet Unified English"))
    }
}
