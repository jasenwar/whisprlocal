import Foundation
import Observation

@MainActor
@Observable
final class HistoryStore {
    private let database: LocalDatabase
    var records: [TranscriptionRecord] = []
    var errorMessage: String?

    init(database: LocalDatabase) {
        self.database = database
    }

    func reload() async {
        do {
            records = try await database.transcriptions()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ record: TranscriptionRecord) async {
        do {
            try await database.deleteTranscription(id: record.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class DictionaryStore {
    private let database: LocalDatabase
    var entries: [DictionaryEntry] = []
    var errorMessage: String?

    init(database: LocalDatabase) {
        self.database = database
    }

    var terms: [String] { entries.map(\.term) }

    func reload() async {
        do {
            entries = try await database.dictionaryEntries()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func add(_ term: String) async {
        do {
            try await database.addDictionaryTerm(term)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ entry: DictionaryEntry) async {
        do {
            try await database.deleteDictionaryTerm(id: entry.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class SnippetStore {
    private let database: LocalDatabase
    var snippets: [Snippet] = []
    var errorMessage: String?

    init(database: LocalDatabase) {
        self.database = database
    }

    func reload() async {
        do {
            snippets = try await database.snippets()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func add(trigger: String, replacement: String) async {
        do {
            try await database.addSnippet(trigger: trigger, replacement: replacement)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ snippet: Snippet) async {
        do {
            try await database.deleteSnippet(id: snippet.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
