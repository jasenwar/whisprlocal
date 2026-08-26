import XCTest
@testable import WhisprLocal

final class VocabularyProcessingTests: XCTestCase {
    func testPlanFiltersDisabledAndOtherAppEntriesThenRanksPinned() {
        let entries = [
            entry(id: 1, term: "General", useCount: 20),
            entry(id: 2, term: "Pinned", pinned: 2),
            entry(id: 3, term: "Mail only", app: "com.apple.mail"),
            entry(id: 4, term: "Disabled", enabled: false),
        ]
        let plan = VocabularyPlanner.makePlan(
            entries: entries,
            snippets: [],
            targetBundleIdentifier: "com.apple.mail"
        )
        XCTAssertEqual(
            plan.transcriptionPhrases.map(\.text),
            ["Pinned", "Mail only", "General"]
        )
        XCTAssertEqual(plan.transcriptionPhrases.first?.score, 2.5)
        XCTAssertFalse(plan.cleanupTerms.contains("Disabled"))
    }

    func testPlanProtectsSnippetTriggersDuringCleanup() {
        let snippet = Snippet(
            id: 1,
            trigger: "whisper signature",
            replacement: "Thanks,\nJasen",
            createdAt: .now
        )
        let plan = VocabularyPlanner.makePlan(
            entries: [entry(id: 1, term: "Jasen")],
            snippets: [snippet],
            targetBundleIdentifier: nil
        )

        XCTAssertEqual(plan.cleanupTerms, ["Jasen", "whisper signature"])
    }

    func testResolverAppliesAliasesAndCanonicalCapitalizationInOnePass() {
        let entries = [
            entry(
                id: 1,
                term: "Jasen",
                aliases: ["Jason", "Jayson"]
            ),
            entry(
                id: 2,
                term: "ChatGPT",
                aliases: ["chat g p t"]
            ),
        ]
        let result = VocabularyResolver.resolve(
            "ask Jason about chat   g p t and jayson_value",
            entries: entries
        )
        XCTAssertEqual(
            result.text,
            "ask Jasen about ChatGPT and jayson_value"
        )
        XCTAssertEqual(result.appliedEntryIDs, [1, 2])
    }

    func testGroqPromptIsDeduplicatedAndWithinTokenBudget() {
        let values = ["Jasen", "jasen"]
            + (0..<200).map { "VeryLongTechnicalTerm\($0)" }
        let prompt = GroqAPIClient.transcriptionPrompt(
            preferredSpellings: values
        )
        let value = try! XCTUnwrap(prompt)
        XCTAssertEqual(
            value.lowercased().components(separatedBy: "jasen").count - 1,
            1
        )
        XCTAssertLessThanOrEqual(value.utf8.count, 224 * 4)
        XCTAssertTrue(value.contains("Preserve every spoken digit"))
        XCTAssertTrue(value.contains("(512) 555-0147"))
    }

    func testGroqPromptAlwaysIncludesNaturalPhoneNumberGuidance() {
        let prompt = GroqAPIClient.transcriptionPrompt(preferredSpellings: [])

        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt?.contains("Preserve every spoken digit") == true)
    }

    func testPipelineResolvesSpokenAliasWhenCleanupIsDisabled() async throws {
        let transcription = VocabularyStubTranscriptionEngine(
            text: "send this to Jason"
        )
        let cleanup = VocabularyStubCleanupEngine()
        let vocabulary = [
            entry(id: 11, term: "Jasen", aliases: ["Jason"]),
        ]
        let pipeline = DictationPipeline(
            transcriptionEngine: transcription,
            cleanupEngine: cleanup
        )

        let output = try await pipeline.run(
            request: DictationPipelineRequest(
                samples: [0.1, 0.2],
                hotwords: [HotwordPhrase("Jasen")],
                dictionary: ["Jasen"],
                vocabularyEntries: vocabulary,
                snippets: [],
                cleanupEnabled: false,
                cleanupWarmupTask: nil
            ),
            onProgress: { _ in }
        )

        XCTAssertEqual(output.transcript.text, "send this to Jason")
        XCTAssertEqual(output.correctedText, "send this to Jasen")
        XCTAssertEqual(output.cleanupEngineIdentifier, "disabled")
        XCTAssertEqual(output.appliedVocabularyEntryIDs, [11])
        let correctionCount = await cleanup.correctionCount
        XCTAssertEqual(correctionCount, 0)
    }

    private func entry(
        id: Int64,
        term: String,
        aliases: [String] = [],
        pinned: Int = 0,
        enabled: Bool = true,
        app: String? = nil,
        useCount: Int = 0
    ) -> DictionaryEntry {
        DictionaryEntry(
            id: id,
            canonicalTerm: term,
            spokenAliases: aliases,
            pinnedPriority: pinned,
            isEnabled: enabled,
            appBundleID: app,
            useCount: useCount,
            createdAt: .now
        )
    }
}

private actor VocabularyStubTranscriptionEngine: TranscriptionEngine {
    let text: String

    init(text: String) {
        self.text = text
    }

    func transcribe(
        samples: [Float],
        sampleRate: Int,
        hotwords: [String]
    ) -> Transcript {
        Transcript(text: text, engine: "Vocabulary test", duration: 0)
    }

    func prewarm() {}
    func releaseIfIdle() {}
}

private actor VocabularyStubCleanupEngine: CleanupEngine {
    private(set) var correctionCount = 0

    func correct(text: String, dictionary: [String]) -> String {
        correctionCount += 1
        return text
    }
}
