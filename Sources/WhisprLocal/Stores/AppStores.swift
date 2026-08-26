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

    /// Compatibility vocabulary for callers that do not provide a dictated-to
    /// app bundle. Only global enabled entries are safe in that situation.
    var terms: [String] {
        var seen = Set<String>()
        return entries
            .filter { $0.isEnabled && $0.appBundleID == nil }
            .flatMap { [$0.canonicalTerm] + $0.spokenAliases }
            .filter { term in
                let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return seen.insert(key).inserted
            }
    }

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

    func add(
        canonicalTerm: String,
        spokenAliases: [String],
        kind: DictionaryEntryKind,
        isPinned: Bool,
        isEnabled: Bool,
        appBundleID: String?
    ) async {
        do {
            try await database.addDictionaryEntry(
                canonicalTerm: canonicalTerm,
                spokenAliases: spokenAliases,
                kind: kind,
                pinnedPriority: isPinned ? 1 : 0,
                isEnabled: isEnabled,
                appBundleID: appBundleID
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(
        _ entry: DictionaryEntry,
        canonicalTerm: String,
        spokenAliases: [String],
        kind: DictionaryEntryKind,
        isPinned: Bool,
        isEnabled: Bool,
        appBundleID: String?
    ) async {
        do {
            try await database.updateDictionaryEntry(
                id: entry.id,
                canonicalTerm: canonicalTerm,
                spokenAliases: spokenAliases,
                kind: kind,
                pinnedPriority: isPinned ? max(1, entry.pinnedPriority) : 0,
                isEnabled: isEnabled,
                appBundleID: appBundleID,
                source: entry.source
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func teach(
        canonicalTerm: String,
        spokenAlias: String,
        appBundleID: String? = nil
    ) async {
        let canonical = canonicalTerm.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let alias = spokenAlias.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !canonical.isEmpty, !alias.isEmpty else { return }
        do {
            if let existing = entries.first(where: {
                $0.canonicalTerm.caseInsensitiveCompare(canonical)
                    == .orderedSame
            }) {
                try await database.updateDictionaryEntry(
                    id: existing.id,
                    canonicalTerm: existing.canonicalTerm,
                    spokenAliases: existing.spokenAliases + [alias],
                    kind: existing.kind,
                    pinnedPriority: existing.pinnedPriority,
                    isEnabled: true,
                    appBundleID: existing.appBundleID,
                    source: existing.source
                )
            } else {
                try await database.addDictionaryEntry(
                    canonicalTerm: canonical,
                    spokenAliases: [alias],
                    kind: Self.suggestedKind(for: canonical),
                    appBundleID: appBundleID,
                    source: .suggestion
                )
            }
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recordUsage(entryIDs: [Int64]) async {
        guard !entryIDs.isEmpty else { return }
        do {
            for id in Set(entryIDs) {
                try await database.recordDictionaryUse(id: id)
            }
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

    private static func suggestedKind(
        for canonicalTerm: String
    ) -> DictionaryEntryKind {
        let letters = canonicalTerm.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) {
            return .acronym
        }
        if canonicalTerm.first?.isUppercase == true {
            return .name
        }
        return .general
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
