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

    func testLegacyMigrationIsReadOnlyAndIdempotent() async throws {
        let sourcePath = temporaryDatabasePath()
        try createLegacyDatabase(at: sourcePath)
        let originalData = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        let database = try LocalDatabase(path: temporaryDatabasePath())

        let first = try await database.importOpenWhisprIfNeeded(from: sourcePath)
        let second = try await database.importOpenWhisprIfNeeded(from: sourcePath)

        XCTAssertEqual(first.transcriptions, 1)
        XCTAssertEqual(first.dictionaryTerms, 1)
        XCTAssertEqual(first.snippets, 1)
        XCTAssertTrue(second.alreadyImported)
        let records = try await database.transcriptions()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sourcePath)), originalData)
    }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "WhisprLocalTests-\(UUID()).sqlite")
            .path
    }

    private func createLegacyDatabase(at path: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = """
        CREATE TABLE transcriptions (
            id INTEGER PRIMARY KEY, text TEXT, timestamp REAL, created_at REAL,
            raw_text TEXT, audio_duration_ms REAL, provider TEXT, deleted_at REAL
        );
        CREATE TABLE custom_dictionary (
            id INTEGER PRIMARY KEY, word TEXT, created_at REAL, deleted_at REAL
        );
        CREATE TABLE snippets (
            id INTEGER PRIMARY KEY, trigger TEXT, replacement TEXT,
            created_at REAL, deleted_at REAL
        );
        INSERT INTO transcriptions
            (text, raw_text, created_at, audio_duration_ms, provider)
            VALUES ('Hello.', 'hello', 100, 900, 'legacy');
        INSERT INTO custom_dictionary (word, created_at) VALUES ('Jasen', 100);
        INSERT INTO snippets (trigger, replacement, created_at)
            VALUES ('my email', 'me@example.com', 100);
        """
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw NSError(
                domain: "DatabaseTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: message.map { String(cString: $0) } ?? ""
                ]
            )
        }
    }
}
