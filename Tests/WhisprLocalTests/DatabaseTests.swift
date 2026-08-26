import Foundation
import SQLite3
import XCTest
@testable import WhisprLocal

final class DatabaseTests: XCTestCase {
    func testCRUD() async throws {
        let database = try LocalDatabase(path: temporaryDatabasePath())
        _ = try await database.insertTranscription(
            rawText: "hello world",
            correctedText: "Hello, world.",
            audioDuration: 1,
            processingLatency: 0.5,
            transcriptionEngine: "test",
            cleanupEngine: "test",
            status: "completed"
        )
        try await database.addDictionaryTerm("WhisprLocal")
        try await database.addSnippet(trigger: "my email", replacement: "me@example.com")

        let transcriptions = try await database.transcriptions()
        let dictionary = try await database.dictionaryEntries()
        let snippets = try await database.snippets()
        XCTAssertEqual(transcriptions.count, 1)
        XCTAssertEqual(dictionary.map(\.term), ["WhisprLocal"])
        XCTAssertEqual(snippets.map(\.trigger), ["my email"])
    }

    func testMultilineSnippetRoundTripsAndExpandsWithoutLosingFormatting() async throws {
        let database = try LocalDatabase(path: temporaryDatabasePath())
        let replacement = """
        Thanks,
        Jasen
        """
        try await database.addSnippet(
            trigger: "whisper signature",
            replacement: replacement
        )

        let snippets = try await database.snippets()
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets[0].replacement, replacement)
        XCTAssertEqual(
            SnippetExpander.expand("Use whisper signature", snippets: snippets),
            "Use.\nThanks,\nJasen"
        )
    }

    func testVocabularyCRUDNormalizesAliasesAndTracksUse() async throws {
        let database = try LocalDatabase(path: temporaryDatabasePath())
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let id = try await database.addDictionaryEntry(
            canonicalTerm: "  WhisprLocal  ",
            spokenAliases: ["whisper local", "Whisper Local", "", "WHISPRLOCAL"],
            kind: .product,
            pinnedPriority: 4,
            appBundleID: "com.example.whispr",
            source: .suggestion,
            createdAt: createdAt,
            updatedAt: createdAt
        )

        var entries = try await database.dictionaryEntries()
        var entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.canonicalTerm, "WhisprLocal")
        XCTAssertEqual(entry.term, "WhisprLocal")
        XCTAssertEqual(entry.spokenAliases, ["whisper local"])
        XCTAssertEqual(entry.kind, .product)
        XCTAssertEqual(entry.pinnedPriority, 4)
        XCTAssertTrue(entry.isEnabled)
        XCTAssertEqual(entry.appBundleID, "com.example.whispr")
        XCTAssertEqual(entry.source, .suggestion)
        XCTAssertEqual(entry.createdAt, createdAt)

        let usedAt = createdAt.addingTimeInterval(60)
        try await database.recordDictionaryUse(id: id, usedAt: usedAt)
        try await database.updateDictionaryEntry(
            id: id,
            canonicalTerm: "Whispr Local",
            spokenAliases: ["whisper local", "WhisprLocal"],
            kind: .technical,
            pinnedPriority: 0,
            isEnabled: false,
            appBundleID: nil,
            source: .manual,
            updatedAt: usedAt.addingTimeInterval(60)
        )

        entries = try await database.dictionaryEntries()
        entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.canonicalTerm, "Whispr Local")
        XCTAssertEqual(entry.spokenAliases, ["whisper local", "WhisprLocal"])
        XCTAssertEqual(entry.kind, .technical)
        XCTAssertFalse(entry.isPinned)
        XCTAssertFalse(entry.isEnabled)
        XCTAssertNil(entry.appBundleID)
        XCTAssertEqual(entry.source, .manual)
        XCTAssertEqual(entry.useCount, 1)
        XCTAssertEqual(entry.lastUsedAt, usedAt)
    }

    func testLegacyVersionZeroDictionaryMigratesWithoutLosingData() async throws {
        let path = temporaryDatabasePath()
        let originalDate = Date(timeIntervalSince1970: 1_650_000_000)
        try createLegacyVersionZeroDatabase(path: path, term: "Ada Lovelace", createdAt: originalDate)

        let database = try LocalDatabase(path: path)
        let schemaVersion = try await database.schemaVersion()
        XCTAssertEqual(schemaVersion, 2)

        let entries = try await database.dictionaryEntries()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.term, "Ada Lovelace")
        XCTAssertEqual(entry.canonicalTerm, "Ada Lovelace")
        XCTAssertEqual(entry.spokenAliases, [])
        XCTAssertEqual(entry.kind, .general)
        XCTAssertFalse(entry.isPinned)
        XCTAssertTrue(entry.isEnabled)
        XCTAssertNil(entry.appBundleID)
        XCTAssertEqual(entry.source, .manual)
        XCTAssertEqual(entry.useCount, 0)
        XCTAssertNil(entry.lastUsedAt)
        XCTAssertEqual(entry.createdAt, originalDate)
        XCTAssertEqual(entry.updatedAt, originalDate)
    }

    func testActiveVocabularyRespectsEnabledAndAppScope() async throws {
        let database = try LocalDatabase(path: temporaryDatabasePath())
        try await database.addDictionaryEntry(canonicalTerm: "Global")
        try await database.addDictionaryEntry(canonicalTerm: "Scoped", appBundleID: "com.example.app")
        try await database.addDictionaryEntry(canonicalTerm: "Disabled", isEnabled: false)

        let appEntries = try await database.activeDictionaryEntries(appBundleID: "com.example.app")
        let globalEntries = try await database.activeDictionaryEntries()
        XCTAssertEqual(appEntries.map(\.canonicalTerm), ["Global", "Scoped"])
        XCTAssertEqual(globalEntries.map(\.canonicalTerm), ["Global"])
    }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "WhisprLocalTests-\(UUID()).sqlite")
            .path
    }

    private func createLegacyVersionZeroDatabase(path: String, term: String, createdAt: Date) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let schema = """
        CREATE TABLE dictionary (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            term TEXT NOT NULL COLLATE NOCASE UNIQUE,
            created_at REAL NOT NULL
        );
        CREATE TABLE transcriptions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            raw_text TEXT NOT NULL,
            corrected_text TEXT NOT NULL,
            created_at REAL NOT NULL,
            audio_duration REAL NOT NULL DEFAULT 0,
            processing_latency REAL NOT NULL DEFAULT 0,
            transcription_engine TEXT NOT NULL,
            cleanup_engine TEXT NOT NULL,
            status TEXT NOT NULL
        );
        CREATE TABLE snippets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trigger TEXT NOT NULL COLLATE NOCASE UNIQUE,
            replacement TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """
        XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)

        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(database, "INSERT INTO dictionary (term, created_at) VALUES (?, ?);", -1, &statement, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, term, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(statement, 2, createdAt.timeIntervalSince1970)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }
}
