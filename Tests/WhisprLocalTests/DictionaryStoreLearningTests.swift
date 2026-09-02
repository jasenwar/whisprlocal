import Foundation
import XCTest
@testable import WhisprLocal

@MainActor
final class DictionaryStoreLearningTests: XCTestCase {
    func testLearningCreatesGlobalLearnedEntryAndUndoRemovesBatch() async throws {
        let database = try LocalDatabase(path: temporaryDatabasePath())
        let store = DictionaryStore(database: database)

        let result = await store.learnCorrections([
            CorrectionCandidate(original: "Jason", replacement: "Jasen"),
            CorrectionCandidate(original: "WhisperLocal", replacement: "WhisprLocal")
        ])

        let event = try XCTUnwrap(result)
        XCTAssertEqual(event.corrections, [
            CorrectionCandidate(original: "Jason", replacement: "Jasen"),
            CorrectionCandidate(original: "WhisperLocal", replacement: "WhisprLocal")
        ])
        XCTAssertEqual(event.title, "Added to Dictionary")
        XCTAssertEqual(event.detail, "Jason → Jasen  +1 more")
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertTrue(store.entries.allSatisfy { $0.appBundleID == nil })
        XCTAssertTrue(store.entries.allSatisfy { $0.source == .learnedCorrection })
        XCTAssertEqual(store.learnedNotice, "Learned 2 corrections")
        XCTAssertTrue(store.canUndoLatestLearning)

        await store.undoLatestLearning()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.learnedNotice)
        XCTAssertFalse(store.canUndoLatestLearning)
    }

    func testLearningIsIdempotentAndUndoRestoresDisabledExistingEntry() async throws {
        let database = try LocalDatabase(path: temporaryDatabasePath())
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let id = try await database.addDictionaryEntry(
            canonicalTerm: "Jasen",
            spokenAliases: ["Jayson"],
            kind: .name,
            pinnedPriority: 2,
            isEnabled: false,
            appBundleID: nil,
            source: .manual,
            createdAt: originalDate,
            updatedAt: originalDate
        )
        let store = DictionaryStore(database: database)

        let firstResult = await store.learnCorrections([
            CorrectionCandidate(original: "Jason", replacement: "Jasen"),
            CorrectionCandidate(original: "jason", replacement: "Jasen")
        ])

        XCTAssertEqual(
            firstResult?.corrections,
            [CorrectionCandidate(original: "Jason", replacement: "Jasen")]
        )
        var learned = try XCTUnwrap(store.entries.first { $0.id == id })
        XCTAssertEqual(learned.spokenAliases, ["Jayson", "Jason"])
        XCTAssertFalse(learned.isEnabled)
        XCTAssertEqual(learned.source, .manual)

        let duplicateResult = await store.learnCorrections([
            CorrectionCandidate(original: "Jason", replacement: "Jasen")
        ])
        XCTAssertNil(duplicateResult)
        learned = try XCTUnwrap(store.entries.first { $0.id == id })
        XCTAssertEqual(learned.spokenAliases, ["Jayson", "Jason"])
        XCTAssertTrue(store.canUndoLatestLearning)

        await store.undoLatestLearning()
        let restored = try XCTUnwrap(store.entries.first { $0.id == id })
        XCTAssertEqual(restored.spokenAliases, ["Jayson"])
        XCTAssertEqual(restored.kind, .name)
        XCTAssertEqual(restored.pinnedPriority, 2)
        XCTAssertFalse(restored.isEnabled)
        XCTAssertNil(restored.appBundleID)
        XCTAssertEqual(restored.source, .manual)
        XCTAssertEqual(restored.updatedAt, originalDate)
    }

    func testLearningDoesNotBroadenAnExistingScopedEntry() async throws {
        let database = try LocalDatabase(path: temporaryDatabasePath())
        try await database.addDictionaryEntry(
            canonicalTerm: "Jasen",
            appBundleID: "com.example.editor",
            source: .manual
        )
        let store = DictionaryStore(database: database)

        let result = await store.learn(corrections: [
            CorrectionCandidate(original: "Jason", replacement: "Jasen")
        ])

        XCTAssertNil(result)
        XCTAssertEqual(store.entries.count, 1)
        let scoped = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(scoped.appBundleID, "com.example.editor")
        XCTAssertTrue(scoped.spokenAliases.isEmpty)
        XCTAssertFalse(store.canUndoLatestLearning)
    }

    func testLearningAcceptsAcronymCapitalizationWithoutDuplicateAlias() async throws {
        let database = try LocalDatabase(path: temporaryDatabasePath())
        let store = DictionaryStore(database: database)

        let result = await store.learnCorrections([
            CorrectionCandidate(original: "api", replacement: "API")
        ])

        XCTAssertEqual(
            result?.corrections,
            [CorrectionCandidate(original: "api", replacement: "API")]
        )
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.canonicalTerm, "API")
        XCTAssertEqual(entry.spokenAliases, [])
        XCTAssertEqual(entry.source, .learnedCorrection)
        XCTAssertEqual(store.learnedNotice, "Learned api → API")
    }

    func testUsageAccountingDoesNotDiscardLearningUndo() async throws {
        let database = try LocalDatabase(path: temporaryDatabasePath())
        let store = DictionaryStore(database: database)

        await store.learnCorrections([
            CorrectionCandidate(original: "Jason", replacement: "Jasen")
        ])
        let learnedID = try XCTUnwrap(store.entries.first?.id)

        await store.recordUsage(entryIDs: [learnedID])

        XCTAssertTrue(store.canUndoLatestLearning)
        XCTAssertNotNil(store.learnedNotice)
        await store.undoLatestLearning()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testLearningEventIncludesOnlyMappingsThatChangedTheDatabase() async throws {
        let database = try LocalDatabase(path: temporaryDatabasePath())
        try await database.addDictionaryEntry(
            canonicalTerm: "Jasen",
            spokenAliases: ["Jayson"],
            kind: .name,
            source: .manual
        )
        try await database.addDictionaryEntry(
            canonicalTerm: "WhisprLocal",
            appBundleID: "com.example.editor",
            source: .manual
        )
        let store = DictionaryStore(database: database)

        let result = await store.learnCorrections([
            CorrectionCandidate(original: "Jason", replacement: "Jasen"),
            CorrectionCandidate(original: "jason", replacement: "Jasen"),
            CorrectionCandidate(original: "Whisper Local", replacement: "WhisprLocal"),
            CorrectionCandidate(original: "croc", replacement: "grok")
        ])

        let event = try XCTUnwrap(result)
        XCTAssertEqual(event.corrections, [
            CorrectionCandidate(original: "Jason", replacement: "Jasen"),
            CorrectionCandidate(original: "croc", replacement: "grok")
        ])
        XCTAssertEqual(event.detail, "Jason → Jasen  +1 more")
        XCTAssertEqual(store.learnedNotice, "Learned 2 corrections")
    }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "WhisprLocalLearningTests-\(UUID()).sqlite")
            .path
    }
}
