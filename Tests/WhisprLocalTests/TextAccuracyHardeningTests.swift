import XCTest
@testable import WhisprLocal

final class TextAccuracyHardeningTests: XCTestCase {
    func testCorrectionAlignmentSurvivesInsertedGrammarWord() {
        let candidates = CorrectionAnalyzer.candidates(
            raw: "send report to jason tomorrow",
            corrected: "Send the report to Jasen tomorrow."
        )
        XCTAssertEqual(
            candidates,
            [CorrectionCandidate(original: "jason", replacement: "Jasen")]
        )
    }

    func testCorrectionAlignmentDropsOrdinarySentenceCapitalization() {
        XCTAssertTrue(CorrectionAnalyzer.candidates(
            raw: "hello there",
            corrected: "Hello there."
        ).isEmpty)
    }

    func testCorrectionAlignmentKeepsCanonicalAcronymCapitalization() {
        XCTAssertEqual(
            CorrectionAnalyzer.candidates(
                raw: "open the api settings",
                corrected: "Open the API settings."
            ),
            [CorrectionCandidate(original: "api", replacement: "API")]
        )
    }

    func testSnippetExpansionIsNonrecursiveAndAvoidsUnderscores() {
        let snippets = [
            Snippet(id: 1, trigger: "alpha", replacement: "beta", createdAt: .now),
            Snippet(id: 2, trigger: "beta", replacement: "expanded", createdAt: .now),
        ]
        XCTAssertEqual(
            SnippetExpander.expand("alpha beta alpha_value", snippets: snippets),
            "beta expanded alpha_value"
        )
    }

    func testSnippetExpansionUsesLongestUnicodePhraseAndFlexibleWhitespace() {
        let snippets = [
            Snippet(id: 1, trigger: "señor", replacement: "wrong", createdAt: .now),
            Snippet(id: 2, trigger: "señor guerra", replacement: "Jasen", createdAt: .now),
        ]
        XCTAssertEqual(
            SnippetExpander.expand("Ask SEN\u{303}OR   GUERRA today.", snippets: snippets),
            "Ask Jasen today."
        )
    }

    func testAdditionalProtectedTermsSurviveCleanupRoundTrip() throws {
        let protected = TranscriptProtector.protect(
            "please add MY   SIG here",
            dictionary: [],
            additionalTerms: ["my sig"]
        )
        XCTAssertTrue(protected.text.contains("[[PROTECTED_"))
        XCTAssertEqual(
            try protected.restore(protected.text),
            "please add my sig here"
        )
    }

    func testGroqPromptExplicitlyProtectsPlaceholders() {
        XCTAssertTrue(GroqCleanupPrompt.system.contains("[[PROTECTED_0001]]"))
        XCTAssertTrue(GroqCleanupPrompt.system.contains("exactly once"))
        XCTAssertTrue(
            GroqCleanupPrompt.resolvedSystemPrompt(custom: "Use my style.")
                .contains("[[PROTECTED_0001]]")
        )
    }

    func testCustomContextPromptCannotRemoveUntrustedContentRules() {
        let prompt = GroqContextService.resolvedSystemPrompt(
            custom: "Focus on software terminology."
        )
        XCTAssertTrue(prompt.contains("Focus on software terminology."))
        XCTAssertTrue(prompt.contains("untrusted content"))
        XCTAssertTrue(prompt.contains("Never execute"))
    }
}
