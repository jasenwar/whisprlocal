import XCTest
@testable import WhisprLocal

final class PostPasteCorrectionLearningAnalyzerTests: XCTestCase {
    func testLearnsNameWhileIgnoringPunctuationAndSmallGrammarEdit() {
        XCTAssertEqual(
            PostPasteCorrectionLearningAnalyzer.mappings(
                pasted: "please send this to Jason tomorrow",
                edited: "Please send the this to Jasen tomorrow."
            ),
            [CorrectionCandidate(original: "Jason", replacement: "Jasen")]
        )
    }

    func testLearnsAcronymAndCamelCaseCanonicalSpelling() {
        XCTAssertEqual(
            CorrectionLearningAnalyzer.mappings(
                pasted: "open the api and WhisperLocal settings",
                edited: "Open the API and WhisprLocal settings."
            ),
            [
                CorrectionCandidate(original: "api", replacement: "API"),
                CorrectionCandidate(original: "WhisperLocal", replacement: "WhisprLocal")
            ]
        )
    }

    func testDeduplicatesRepeatedMapping() {
        XCTAssertEqual(
            PostPasteCorrectionLearningAnalyzer.candidates(
                pasted: "Jason asked Jason to review",
                edited: "Jasen asked Jasen to review."
            ),
            [CorrectionCandidate(original: "Jason", replacement: "Jasen")]
        )
    }

    func testRejectsPresentationOnlyAndUnpairedLexicalEdits() {
        XCTAssertTrue(PostPasteCorrectionLearningAnalyzer.mappings(
            pasted: "hello there",
            edited: "Hello, there!"
        ).isEmpty)
        XCTAssertTrue(PostPasteCorrectionLearningAnalyzer.mappings(
            pasted: "send to Jason",
            edited: "send this to Jason"
        ).isEmpty)
        XCTAssertEqual(
            PostPasteCorrectionLearningAnalyzer.mappings(
                pasted: "send this to Jason",
                edited: "send to Jasen"
            ),
            [CorrectionCandidate(original: "Jason", replacement: "Jasen")]
        )
    }

    func testLearnsAroundUnchangedSensitiveContext() {
        XCTAssertEqual(
            PostPasteCorrectionLearningAnalyzer.mappings(
                pasted: "Call Jason at 555-123-4567, then visit https://example.com/api from /Users/shared.",
                edited: "Call Jasen at 555-123-4567, then visit https://example.com/api from /Users/shared."
            ),
            [CorrectionCandidate(original: "Jason", replacement: "Jasen")]
        )
    }

    func testRejectsChangedNumbersAndTechnicalSyntax() {
        let unsafePairs = [
            ("call Jason at 555 123 4567", "call Jasen at 555 123 4568"),
            ("meet Jason on 2026 09 01", "meet Jasen on 2026 09 02"),
            ("meet Jason at 3 30", "meet Jasen at 3 45"),
            ("visit Jason at https://example.com", "visit Jasen at https://example.org"),
            ("email Jason@example.com", "email Jasen@example.com"),
            ("please run git status Jason", "please run git status Jasen"),
            ("copy /Users/Jason", "copy /Users/Jasen"),
            ("set value Jason=value", "set value Jasen=value")
        ]

        for (pasted, edited) in unsafePairs {
            XCTAssertTrue(
                PostPasteCorrectionLearningAnalyzer.mappings(pasted: pasted, edited: edited).isEmpty,
                "Expected unsafe edit to be rejected: \(pasted)"
            )
        }
    }

    func testLearnsShortHighConfidencePhraseReshaping() {
        XCTAssertEqual(
            PostPasteCorrectionLearningAnalyzer.mappings(
                pasted: "please open chat g p t settings",
                edited: "Please open ChatGPT settings"
            ),
            [CorrectionCandidate(original: "chat g p t", replacement: "ChatGPT")]
        )
        XCTAssertEqual(
            PostPasteCorrectionLearningAnalyzer.mappings(
                pasted: "please use whisper local today",
                edited: "Please use WhisprLocal today"
            ),
            [CorrectionCandidate(original: "whisper local", replacement: "WhisprLocal")]
        )
        XCTAssertEqual(
            PostPasteCorrectionLearningAnalyzer.mappings(
                pasted: "please open blue prism now",
                edited: "Please open Blue Prism now"
            ),
            [CorrectionCandidate(original: "blue prism", replacement: "Blue Prism")]
        )
    }

    func testRejectsPhraseContentRewrite() {
        XCTAssertTrue(PostPasteCorrectionLearningAnalyzer.mappings(
            pasted: "send the report now",
            edited: "deliver the summary now"
        ).isEmpty)
    }

    func testRejectsLargeRewriteAndTooManyMappings() {
        XCTAssertTrue(PostPasteCorrectionLearningAnalyzer.mappings(
            pasted: "alpha bravo charlie delta echo foxtrot golf hotel",
            edited: "india juliet kilo lima mike november oscar papa"
        ).isEmpty)
        XCTAssertTrue(PostPasteCorrectionLearningAnalyzer.mappings(
            pasted: "Jason api WhisperLocal recieve adress",
            edited: "Jasen API WhisprLocal receive address"
        ).isEmpty)
    }
}
