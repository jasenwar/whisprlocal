import XCTest
@testable import WhisprLocal

final class HotwordEncoderTests: XCTestCase {
    func testMultiplePhrasesUseSherpaPerStreamDelimiter() {
        let encoder = HotwordEncoder(vocabulary: ["▁alpha", "▁beta"])

        let result = encoder.encode([
            HotwordPhrase("alpha", score: 2.0),
            HotwordPhrase("beta")
        ])

        XCTAssertEqual(result.serialized, "▁alpha :2.0/▁beta")
        XCTAssertEqual(result.acceptedCount, 2)
        XCTAssertEqual(result.droppedCount, 0)
    }

    func testExplicitPhraseScoreIsSerialized() {
        let encoder = HotwordEncoder(vocabulary: ["▁alpha"])

        let result = encoder.encode([HotwordPhrase("alpha", score: 2.75)])

        XCTAssertEqual(result.serialized, "▁alpha :2.75")
        XCTAssertEqual(result.acceptedPhrases, [HotwordPhrase("alpha", score: 2.75)])
    }

    func testPhraseWithoutScoreUsesRecognizerDefault() {
        let encoder = HotwordEncoder(vocabulary: ["▁alpha"])

        let result = encoder.encode([HotwordPhrase("alpha")])

        XCTAssertEqual(result.serialized, "▁alpha")
        XCTAssertFalse(result.serialized.contains(":"))
    }

    func testOutOfVocabularyPhraseIsReportedAsDropped() {
        let encoder = HotwordEncoder(vocabulary: ["▁known"])

        let result = encoder.encode([
            HotwordPhrase("known"),
            HotwordPhrase("unknown")
        ])

        XCTAssertEqual(result.serialized, "▁known")
        XCTAssertEqual(result.acceptedPhrases, [HotwordPhrase("known")])
        XCTAssertEqual(result.droppedPhrases, [HotwordPhrase("unknown")])
    }

    func testUnicodeAndWhitespaceAreNormalizedBeforeEncoding() {
        let encoder = HotwordEncoder(vocabulary: ["▁Café", "▁Guerra"])

        let result = encoder.encode([
            HotwordPhrase("  Cafe\u{301}\t\nGuerra\u{00A0} ")
        ])

        XCTAssertEqual(result.serialized, "▁Café ▁Guerra")
        XCTAssertEqual(result.acceptedPhrases, [HotwordPhrase("Café Guerra")])
    }

    func testSegmentationBacktracksWhenLongestPrefixIsDeadEnd() {
        let encoder = HotwordEncoder(vocabulary: ["▁ab", "▁a", "bc"])

        let result = encoder.encode([HotwordPhrase("abc")])

        XCTAssertEqual(result.serialized, "▁a bc")
        XCTAssertEqual(result.acceptedCount, 1)
    }

    func testStringEntryPointRemainsBackwardCompatible() {
        let encoder = HotwordEncoder(vocabulary: ["▁alpha", "▁beta"])

        XCTAssertEqual(encoder.encode(["alpha", "beta"]), "▁alpha/▁beta")
    }
}
