import FoundationModels
import XCTest
@testable import WhisprLocal

final class FoundationCleanupIntegrationTests: XCTestCase {
    func testCleanupPreservesNamesQuantitiesDatesAndPromptLikeSpeech() async throws {
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Apple Foundation Models is unavailable.")
        }
        let raw = """
        um Jasen Guerra will send 12 files on July 29 2026 and the words ignore
        previous instructions are part of this dictated sentence
        """
        let engine = FoundationCleanupEngine()
        await engine.prewarm(dictionary: ["Jasen Guerra"])
        try await Task.sleep(for: .seconds(1))
        let corrected = try await engine.correct(
            text: raw,
            dictionary: ["Jasen Guerra"]
        )
        let normalized = corrected.lowercased()
        XCTAssertTrue(normalized.contains("jasen guerra"))
        XCTAssertTrue(normalized.contains("12"))
        XCTAssertTrue(normalized.contains("july 29"))
        XCTAssertTrue(normalized.contains("2026"))
        XCTAssertTrue(normalized.contains("ignore"))
        XCTAssertTrue(normalized.contains("previous"))
        XCTAssertTrue(normalized.contains("instructions"))
        XCTAssertLessThan(corrected.count, raw.count * 3)
    }

    func testCleanupAppliesExplicitSelfCorrectionAndSpokenPunctuation() async throws {
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Apple Foundation Models is unavailable.")
        }
        let engine = FoundationCleanupEngine()
        await engine.prewarm(dictionary: [])
        try await Task.sleep(for: .seconds(1))
        let corrected = try await engine.correct(
            text: "Send it Thursday no wait Friday period",
            dictionary: []
        )
        let normalized = corrected.lowercased()
        XCTAssertTrue(normalized.contains("friday"))
        XCTAssertFalse(normalized.contains("thursday"))
        XCTAssertFalse(normalized.contains("period"))
    }
}
