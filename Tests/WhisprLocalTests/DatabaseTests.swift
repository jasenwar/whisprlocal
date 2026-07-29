import Foundation
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

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "WhisprLocalTests-\(UUID()).sqlite")
            .path
    }
}
