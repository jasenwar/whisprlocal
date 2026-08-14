import Foundation
import SQLite3

actor LocalDatabase {
    static let shared: LocalDatabase = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(
            path: BuildFlavor.applicationSupportDirectoryName,
            directoryHint: .isDirectory
        )
        try? FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )
        return try! LocalDatabase(path: support.appending(path: "whisprlocal.sqlite").path)
    }()

    let path: String
    private let database: SQLiteHandle
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var handle: OpaquePointer { database.pointer }

    init(path: String) throws {
        self.path = path
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw DatabaseError.open(String(cString: sqlite3_errmsg(database)))
        }
        guard let database else {
            throw DatabaseError.open("SQLite returned no database handle.")
        }
        self.database = SQLiteHandle(database)
        try Self.execute(on: database, sql: "PRAGMA journal_mode=WAL;")
        try Self.execute(on: database, sql: "PRAGMA foreign_keys=ON;")
        try Self.createSchema(on: database)
    }

    func insertTranscription(
        rawText: String,
        correctedText: String,
        createdAt: Date = Date(),
        audioDuration: TimeInterval,
        processingLatency: TimeInterval,
        transcriptionEngine: String,
        cleanupEngine: String,
        status: String
    ) throws -> Int64 {
        let sql = """
        INSERT INTO transcriptions (
            raw_text, corrected_text, created_at, audio_duration,
            processing_latency, transcription_engine, cleanup_engine, status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(rawText, at: 1, in: statement)
        bind(correctedText, at: 2, in: statement)
        sqlite3_bind_double(statement, 3, createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, audioDuration)
        sqlite3_bind_double(statement, 5, processingLatency)
        bind(transcriptionEngine, at: 6, in: statement)
        bind(cleanupEngine, at: 7, in: statement)
        bind(status, at: 8, in: statement)
        try stepDone(statement)
        return sqlite3_last_insert_rowid(handle)
    }

    func transcriptions(limit: Int = 500) throws -> [TranscriptionRecord] {
        let statement = try prepare("""
        SELECT id, raw_text, corrected_text, created_at, audio_duration,
               processing_latency, transcription_engine, cleanup_engine, status
        FROM transcriptions
        ORDER BY created_at DESC
        LIMIT ?;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var records: [TranscriptionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(TranscriptionRecord(
                id: sqlite3_column_int64(statement, 0),
                rawText: string(statement, 1),
                correctedText: string(statement, 2),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                audioDuration: sqlite3_column_double(statement, 4),
                processingLatency: sqlite3_column_double(statement, 5),
                transcriptionEngine: string(statement, 6),
                cleanupEngine: string(statement, 7),
                status: string(statement, 8)
            ))
        }
        return records
    }

    func deleteTranscription(id: Int64) throws {
        try execute("DELETE FROM transcriptions WHERE id = ?;") { statement in
            sqlite3_bind_int64(statement, 1, id)
        }
    }

    func dictionaryEntries() throws -> [DictionaryEntry] {
        let statement = try prepare("""
        SELECT id, term, created_at FROM dictionary
        ORDER BY term COLLATE NOCASE;
        """)
        defer { sqlite3_finalize(statement) }
        var entries: [DictionaryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            entries.append(DictionaryEntry(
                id: sqlite3_column_int64(statement, 0),
                term: string(statement, 1),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            ))
        }
        return entries
    }

    @discardableResult
    func addDictionaryTerm(_ term: String, createdAt: Date = Date()) throws -> Int64 {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw DatabaseError.invalidValue }
        try execute("""
        INSERT INTO dictionary (term, created_at) VALUES (?, ?)
        ON CONFLICT(term) DO NOTHING;
        """) { statement in
            bind(cleaned, at: 1, in: statement)
            sqlite3_bind_double(statement, 2, createdAt.timeIntervalSince1970)
        }
        return sqlite3_last_insert_rowid(handle)
    }

    func deleteDictionaryTerm(id: Int64) throws {
        try execute("DELETE FROM dictionary WHERE id = ?;") { statement in
            sqlite3_bind_int64(statement, 1, id)
        }
    }

    func snippets() throws -> [Snippet] {
        let statement = try prepare("""
        SELECT id, trigger, replacement, created_at FROM snippets
        ORDER BY length(trigger) DESC, trigger COLLATE NOCASE;
        """)
        defer { sqlite3_finalize(statement) }
        var values: [Snippet] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(Snippet(
                id: sqlite3_column_int64(statement, 0),
                trigger: string(statement, 1),
                replacement: string(statement, 2),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
        }
        return values
    }

    @discardableResult
    func addSnippet(trigger: String, replacement: String, createdAt: Date = Date()) throws -> Int64 {
        let cleanedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTrigger.isEmpty, !replacement.isEmpty else {
            throw DatabaseError.invalidValue
        }
        try execute("""
        INSERT INTO snippets (trigger, replacement, created_at) VALUES (?, ?, ?)
        ON CONFLICT(trigger) DO UPDATE SET replacement = excluded.replacement;
        """) { statement in
            bind(cleanedTrigger, at: 1, in: statement)
            bind(replacement, at: 2, in: statement)
            sqlite3_bind_double(statement, 3, createdAt.timeIntervalSince1970)
        }
        return sqlite3_last_insert_rowid(handle)
    }

    func deleteSnippet(id: Int64) throws {
        try execute("DELETE FROM snippets WHERE id = ?;") { statement in
            sqlite3_bind_int64(statement, 1, id)
        }
    }

    private func execute(
        _ sql: String,
        bindings: (OpaquePointer?) -> Void
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindings(statement)
        try stepDone(statement)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        try Self.prepare(on: handle, sql: sql)
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func string(_ statement: OpaquePointer?, _ index: Int32) -> String {
        Self.string(statement, index)
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private static func createSchema(on database: OpaquePointer?) throws {
        try execute(on: database, sql: """
        CREATE TABLE IF NOT EXISTS transcriptions (
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
        CREATE INDEX IF NOT EXISTS idx_transcriptions_created
            ON transcriptions(created_at DESC);

        CREATE TABLE IF NOT EXISTS dictionary (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            term TEXT NOT NULL COLLATE NOCASE UNIQUE,
            created_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS snippets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trigger TEXT NOT NULL COLLATE NOCASE UNIQUE,
            replacement TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """)
    }

    private static func execute(on database: OpaquePointer?, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let value = message.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(message)
            throw DatabaseError.execute(value)
        }
    }

    private static func prepare(on database: OpaquePointer?, sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.execute(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private static func string(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }
}

enum DatabaseError: LocalizedError {
    case open(String)
    case execute(String)
    case invalidValue

    var errorDescription: String? {
        switch self {
        case .open(let message), .execute(let message): message
        case .invalidValue: "The value cannot be empty."
        }
    }
}

private final class SQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}
