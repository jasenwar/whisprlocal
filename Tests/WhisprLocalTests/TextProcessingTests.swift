import XCTest
@testable import WhisprLocal

final class TextProcessingTests: XCTestCase {
    func testSnippetsAreLongestFirstCaseInsensitiveAndWholePhrase() {
        let snippets = [
            Snippet(id: 1, trigger: "sig", replacement: "wrong", createdAt: .now),
            Snippet(id: 2, trigger: "my sig", replacement: "Jasen Guerra", createdAt: .now)
        ]
        XCTAssertEqual(
            SnippetExpander.expand("Please add MY SIG here.", snippets: snippets),
            "Please add Jasen Guerra here."
        )
        XCTAssertEqual(
            SnippetExpander.expand("signal", snippets: snippets),
            "signal"
        )
    }

    func testTerminalMultilineSnippetIsAnExactBlockAfterCleanupPunctuation() {
        let snippet = Snippet(
            id: 1,
            trigger: "whisper signature",
            replacement: "Thanks,\nJasen",
            createdAt: .now
        )
        XCTAssertEqual(
            SnippetExpander.expand(
                "Please send the project update, whisper signature.",
                snippets: [snippet]
            ),
            "Please send the project update.\nThanks,\nJasen"
        )
    }

    func testTerminalMultilineSnippetPreservesIntentionalLeadingAndBlankLines() {
        let snippet = Snippet(
            id: 1,
            trigger: "whisper signature",
            replacement: "\nThanks,\n\nJasen",
            createdAt: .now
        )
        XCTAssertEqual(
            SnippetExpander.expand(
                "Please send the project update whisper signature.",
                snippets: [snippet]
            ),
            "Please send the project update.\nThanks,\n\nJasen"
        )
    }

    func testCandidateFilterKeepsLikelyNamesAndDropsGrammarStopwords() {
        let candidates = CorrectionAnalyzer.candidates(
            raw: "send it to jason at noon",
            corrected: "Send it to Jasen at noon."
        )
        XCTAssertTrue(candidates.contains {
            $0.original.lowercased() == "jason" && $0.replacement == "Jasen"
        })
        XCTAssertFalse(candidates.contains { $0.original.lowercased() == "it" })
    }

    func testDiffRetainsRawAndCorrectedTokens() {
        let diff = CorrectionAnalyzer.diff(
            raw: "hello their",
            corrected: "Hello there"
        )
        XCTAssertTrue(diff.contains { $0.kind == .removed })
        XCTAssertTrue(diff.contains { $0.kind == .inserted })
    }

    func testHotwordsAreEncodedAsSentencePieceTokensPerStream() {
        let encoder = HotwordEncoder(vocabulary: [
            "▁Ja", "sen", "▁G", "u", "er", "ra"
        ])
        XCTAssertEqual(
            encoder.encode(["Jasen Guerra"]),
            "▁Ja sen ▁G u er ra"
        )
    }

    func testPasteTextEndsWithExactlyOneExistingOrAddedWhitespace() {
        XCTAssertEqual(
            PasteTextFormatter.withTrailingSpace("Dictation complete."),
            "Dictation complete. "
        )
        XCTAssertEqual(
            PasteTextFormatter.withTrailingSpace("Already spaced "),
            "Already spaced "
        )
        XCTAssertEqual(PasteTextFormatter.withTrailingSpace(""), "")
    }
}
