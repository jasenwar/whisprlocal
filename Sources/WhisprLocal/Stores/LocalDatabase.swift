import Foundation
import SQLite3

actor LocalDatabase {
    private static let currentSchemaVersion: Int32 = 2

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
        try Self.migrate(on: database)
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
        let statement = try prepare("""
        INSERT INTO transcriptions (
            raw_text, corrected_text, created_at, audio_duration,
            processing_latency, transcription_engine, cleanup_engine, status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """)
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
        try execute("DELETE FROM transcriptions WHERE id = ?;") { sqlite3_bind_int64($0, 1, id) }
    }

    /// Returns all entries, including disabled and app-scoped entries, for management UI.
    func dictionaryEntries() throws -> [DictionaryEntry] {
        try dictionaryEntries(whereClause: nil, bindValues: [])
    }

    /// Returns enabled entries available to an app. Passing nil returns global entries only.
    func activeDictionaryEntries(appBundleID: String? = nil) throws -> [DictionaryEntry] {
        if let appBundleID = Self.normalizedBundleID(appBundleID) {
            return try dictionaryEntries(
                whereClause: "enabled = 1 AND (app_bundle_id IS NULL OR app_bundle_id = ?)",
                bindValues: [appBundleID]
            )
        }
        return try dictionaryEntries(
            whereClause: "enabled = 1 AND app_bundle_id IS NULL",
            bindValues: []
        )
    }

    @discardableResult
    func addDictionaryTerm(_ term: String, createdAt: Date = Date()) throws -> Int64 {
        try addDictionaryEntry(canonicalTerm: term, createdAt: createdAt, updatedAt: createdAt)
    }

    @discardableResult
    func addDictionaryEntry(
        canonicalTerm: String,
        spokenAliases: [String] = [],
        kind: DictionaryEntryKind = .general,
        pinnedPriority: Int = 0,
        isEnabled: Bool = true,
        appBundleID: String? = nil,
        source: DictionaryEntrySource = .manual,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws -> Int64 {
        let value = try Self.dictionaryValue(
            canonicalTerm: canonicalTerm,
            spokenAliases: spokenAliases,
            pinnedPriority: pinnedPriority,
            appBundleID: appBundleID
        )
        try execute("""
        INSERT INTO dictionary (
            term, canonical_term, spoken_aliases, kind, pinned_priority, enabled,
            app_bundle_id, source, use_count, last_used_at, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?)
        ON CONFLICT(term) DO NOTHING;
        """) { statement in
            bind(value.canonicalTerm, at: 1, in: statement)
            bind(value.canonicalTerm, at: 2, in: statement)
            bind(value.aliasesJSON, at: 3, in: statement)
            bind(kind.rawValue, at: 4, in: statement)
            sqlite3_bind_int(statement, 5, Int32(value.pinnedPriority))
            sqlite3_bind_int(statement, 6, isEnabled ? 1 : 0)
            bindOptional(value.appBundleID, at: 7, in: statement)
            bind(source.rawValue, at: 8, in: statement)
            sqlite3_bind_double(statement, 9, createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 10, updatedAt.timeIntervalSince1970)
        }
        return try dictionaryID(canonicalTerm: value.canonicalTerm)
    }

    func updateDictionaryEntry(
        id: Int64,
        canonicalTerm: String,
        spokenAliases: [String],
        kind: DictionaryEntryKind,
        pinnedPriority: Int,
        isEnabled: Bool,
        appBundleID: String?,
        source: DictionaryEntrySource,
        updatedAt: Date = Date()
    ) throws {
        let value = try Self.dictionaryValue(
            canonicalTerm: canonicalTerm,
            spokenAliases: spokenAliases,
            pinnedPriority: pinnedPriority,
            appBundleID: appBundleID
        )
        try execute("""
        UPDATE dictionary
        SET term = ?, canonical_term = ?, spoken_aliases = ?, kind = ?,
            pinned_priority = ?, enabled = ?, app_bundle_id = ?, source = ?,
            updated_at = ?
        WHERE id = ?;
        """) { statement in
            bind(value.canonicalTerm, at: 1, in: statement)
            bind(value.canonicalTerm, at: 2, in: statement)
            bind(value.aliasesJSON, at: 3, in: statement)
            bind(kind.rawValue, at: 4, in: statement)
            sqlite3_bind_int(statement, 5, Int32(value.pinnedPriority))
            sqlite3_bind_int(statement, 6, isEnabled ? 1 : 0)
            bindOptional(value.appBundleID, at: 7, in: statement)
            bind(source.rawValue, at: 8, in: statement)
            sqlite3_bind_double(statement, 9, updatedAt.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 10, id)
        }
    }

    func recordDictionaryUse(id: Int64, usedAt: Date = Date()) throws {
        try execute("""
        UPDATE dictionary
        SET use_count = use_count + 1, last_used_at = ?, updated_at = ?
        WHERE id = ?;
        """) { statement in
            sqlite3_bind_double(statement, 1, usedAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, usedAt.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 3, id)
        }
    }

    func deleteDictionaryTerm(id: Int64) throws {
        try execute("DELETE FROM dictionary WHERE id = ?;") { sqlite3_bind_int64($0, 1, id) }
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
        guard !cleanedTrigger.isEmpty, !replacement.isEmpty else { throw DatabaseError.invalidValue }
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
        try execute("DELETE FROM snippets WHERE id = ?;") { sqlite3_bind_int64($0, 1, id) }
    }

    func schemaVersion() throws -> Int32 { try Self.userVersion(on: handle) }

    private func dictionaryEntries(whereClause: String?, bindValues: [String]) throws -> [DictionaryEntry] {
        let filter = whereClause.map { "WHERE \($0)" } ?? ""
        let statement = try prepare("""
        SELECT id, canonical_term, spoken_aliases, kind, pinned_priority, enabled,
               app_bundle_id, source, use_count, last_used_at, created_at, updated_at
        FROM dictionary
        \(filter)
        ORDER BY pinned_priority DESC, canonical_term COLLATE NOCASE;
        """)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindValues.enumerated() {
            bind(value, at: Int32(offset + 1), in: statement)
        }
        var entries: [DictionaryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let canonicalTerm = string(statement, 1)
            entries.append(DictionaryEntry(
                id: sqlite3_column_int64(statement, 0),
                canonicalTerm: canonicalTerm,
                spokenAliases: Self.decodeAliases(string(statement, 2), excluding: canonicalTerm),
                kind: DictionaryEntryKind(rawValue: string(statement, 3)) ?? .general,
                pinnedPriority: Int(sqlite3_column_int(statement, 4)),
                isEnabled: sqlite3_column_int(statement, 5) != 0,
                appBundleID: optionalString(statement, 6),
                source: DictionaryEntrySource(rawValue: string(statement, 7)) ?? .manual,
                useCount: Int(sqlite3_column_int(statement, 8)),
                lastUsedAt: optionalDate(statement, 9),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
            ))
        }
        return entries
    }

    private func dictionaryID(canonicalTerm: String) throws -> Int64 {
        let statement = try prepare("SELECT id FROM dictionary WHERE term = ? COLLATE NOCASE LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(canonicalTerm, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw DatabaseError.notFound }
        return sqlite3_column_int64(statement, 0)
    }

    private func execute(_ sql: String, bindings: (OpaquePointer?) -> Void) throws {
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

    private func bindOptional(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bind(value, at: index, in: statement)
    }

    private func string(_ statement: OpaquePointer?, _ index: Int32) -> String { Self.string(statement, index) }

    private func optionalString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let value = string(statement, index).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func optionalDate(_ statement: OpaquePointer?, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private static func migrate(on database: OpaquePointer?) throws {
        try execute(on: database, sql: "BEGIN IMMEDIATE;")
        do {
            var version = try userVersion(on: database)
            if version < 1 {
                try createVersionOneSchema(on: database)
                try setUserVersion(1, on: database)
                version = 1
            }
            if version < 2 {
                try migrateDictionaryToVersionTwo(on: database)
                try setUserVersion(currentSchemaVersion, on: database)
            }
            try execute(on: database, sql: "COMMIT;")
        } catch {
            try? execute(on: database, sql: "ROLLBACK;")
            throw error
        }
    }

    private static func createVersionOneSchema(on database: OpaquePointer?) throws {
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
        CREATE INDEX IF NOT EXISTS idx_transcriptions_created ON transcriptions(created_at DESC);
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

    private static func migrateDictionaryToVersionTwo(on database: OpaquePointer?) throws {
        let columns = try dictionaryColumns(on: database)
        let additions: [(String, String)] = [
            ("canonical_term", "TEXT NOT NULL DEFAULT ''"),
            ("spoken_aliases", "TEXT NOT NULL DEFAULT '[]'"),
            ("kind", "TEXT NOT NULL DEFAULT 'general'"),
            ("pinned_priority", "INTEGER NOT NULL DEFAULT 0"),
            ("enabled", "INTEGER NOT NULL DEFAULT 1"),
            ("app_bundle_id", "TEXT"),
            ("source", "TEXT NOT NULL DEFAULT 'manual'"),
            ("use_count", "INTEGER NOT NULL DEFAULT 0"),
            ("last_used_at", "REAL"),
            ("updated_at", "REAL NOT NULL DEFAULT 0")
        ]
        for (name, definition) in additions where !columns.contains(name) {
            try execute(on: database, sql: "ALTER TABLE dictionary ADD COLUMN \(name) \(definition);")
        }
        try execute(on: database, sql: """
        UPDATE dictionary SET canonical_term = term WHERE trim(canonical_term) = '';
        UPDATE dictionary SET updated_at = created_at WHERE updated_at = 0;
        CREATE INDEX IF NOT EXISTS idx_dictionary_active_scope
            ON dictionary(enabled, app_bundle_id, pinned_priority DESC, canonical_term COLLATE NOCASE);
        """)
    }

    private static func dictionaryColumns(on database: OpaquePointer?) throws -> Set<String> {
        let statement = try prepare(on: database, sql: "PRAGMA table_info(dictionary);")
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { columns.insert(string(statement, 1)) }
        return columns
    }

    private static func userVersion(on database: OpaquePointer?) throws -> Int32 {
        let statement = try prepare(on: database, sql: "PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.execute("Could not read SQLite schema version.")
        }
        return sqlite3_column_int(statement, 0)
    }

    private static func setUserVersion(_ version: Int32, on database: OpaquePointer?) throws {
        try execute(on: database, sql: "PRAGMA user_version = \(version);")
    }

    private static func dictionaryValue(
        canonicalTerm: String,
        spokenAliases: [String],
        pinnedPriority: Int,
        appBundleID: String?
    ) throws -> (canonicalTerm: String, aliasesJSON: String, pinnedPriority: Int, appBundleID: String?) {
        let canonicalTerm = canonicalTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonicalTerm.isEmpty else { throw DatabaseError.invalidValue }
        let aliases = normalizedAliases(spokenAliases, excluding: canonicalTerm)
        let aliasesJSON = String(data: try JSONEncoder().encode(aliases), encoding: .utf8) ?? "[]"
        return (canonicalTerm, aliasesJSON, max(0, pinnedPriority), normalizedBundleID(appBundleID))
    }

    private static func normalizedAliases(_ values: [String], excluding canonicalTerm: String) -> [String] {
        var seen = Set<String>()
        let canonicalKey = canonicalTerm.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return values.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard key != canonicalKey, seen.insert(key).inserted else { return nil }
            return value
        }
    }

    private static func normalizedBundleID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decodeAliases(_ text: String, excluding canonicalTerm: String) -> [String] {
        let data = Data(text.utf8)
        if let values = try? JSONDecoder().decode([String].self, from: data) {
            return normalizedAliases(values, excluding: canonicalTerm)
        }
        // Early experimental builds may have saved plain text. Keep it usable
        // rather than letting one malformed value hide an entire entry.
        let fallback = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map(String.init)
        return normalizedAliases(fallback.isEmpty ? [text] : fallback, excluding: canonicalTerm)
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
    case notFound

    var errorDescription: String? {
        switch self {
        case .open(let message), .execute(let message): message
        case .invalidValue: "The preferred spelling cannot be empty."
        case .notFound: "The dictionary entry could not be found."
        }
    }
}

private final class SQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) { self.pointer = pointer }

    deinit { sqlite3_close(pointer) }
}
