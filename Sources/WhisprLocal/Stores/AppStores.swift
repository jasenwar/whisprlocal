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
    private enum LearningUndoChange {
        case created(id: Int64)
        case modified(before: DictionaryEntry)
    }

    private struct LearningUndoBatch {
        let changes: [LearningUndoChange]
    }

    private let database: LocalDatabase
    private var latestLearningUndo: LearningUndoBatch?
    var entries: [DictionaryEntry] = []
    var errorMessage: String?
    var learnedNotice: String?

    var canUndoLatestLearning: Bool { latestLearningUndo != nil }

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
            clearLearningUndo()
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
            clearLearningUndo()
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
            clearLearningUndo()
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
            clearLearningUndo()
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
            clearLearningUndo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Applies a bounded batch of analyzer-approved mappings to global vocabulary.
    /// Existing entries retain their enabled state, scope, source, and metadata.
    func learnCorrections(_ corrections: [CorrectionCandidate]) async {
        let normalized = Self.normalizedCorrections(corrections)
        guard !normalized.isEmpty else { return }

        do {
            // The observer may fire before the Dictionary view has loaded. Read the
            // database first so an existing global entry is never mistaken for one
            // created by this batch (which would make undo unsafe).
            var workingEntries = try await database.dictionaryEntries()
            var changes: [LearningUndoChange] = []
            var learned: [CorrectionCandidate] = []

            for correction in normalized {
                if let index = workingEntries.firstIndex(where: {
                    $0.appBundleID == nil
                        && $0.canonicalTerm.caseInsensitiveCompare(
                            correction.replacement
                        ) == .orderedSame
                }) {
                    let existing = workingEntries[index]
                    let aliases = Self.deduplicatedAliases(
                        existing.spokenAliases + [correction.original],
                        excluding: existing.canonicalTerm
                    )
                    guard aliases != existing.spokenAliases else { continue }

                    if !changes.contains(where: {
                        if case .modified(let before) = $0 { return before.id == existing.id }
                        return false
                    }) {
                        changes.append(.modified(before: existing))
                    }
                    try await database.updateDictionaryEntry(
                        id: existing.id,
                        canonicalTerm: existing.canonicalTerm,
                        spokenAliases: aliases,
                        kind: existing.kind,
                        pinnedPriority: existing.pinnedPriority,
                        isEnabled: existing.isEnabled,
                        appBundleID: existing.appBundleID,
                        source: existing.source
                    )
                    workingEntries[index].spokenAliases = aliases
                    learned.append(correction)
                } else if workingEntries.contains(where: {
                    $0.canonicalTerm.caseInsensitiveCompare(
                        correction.replacement
                    ) == .orderedSame
                }) {
                    // `canonical_term` is globally unique in the local database.
                    // Do not widen an app-scoped entry just because an automatic
                    // correction happened elsewhere.
                    continue
                } else {
                    let id = try await database.addDictionaryEntry(
                        canonicalTerm: correction.replacement,
                        spokenAliases: [correction.original],
                        kind: Self.suggestedKind(for: correction.replacement),
                        appBundleID: nil,
                        source: .learnedCorrection
                    )
                    changes.append(.created(id: id))
                    workingEntries.append(DictionaryEntry(
                        id: id,
                        canonicalTerm: correction.replacement,
                        spokenAliases: [correction.original],
                        kind: Self.suggestedKind(for: correction.replacement),
                        appBundleID: nil,
                        source: .learnedCorrection,
                        createdAt: .now
                    ))
                    learned.append(correction)
                }
            }

            guard !changes.isEmpty else {
                entries = workingEntries
                errorMessage = nil
                return
            }
            entries = try await database.dictionaryEntries()
            latestLearningUndo = LearningUndoBatch(changes: changes)
            learnedNotice = Self.learningNotice(for: learned)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Compatibility spelling for post-paste monitor call sites.
    func learn(corrections: [CorrectionCandidate]) async {
        await learnCorrections(corrections)
    }

    /// Reverses the most recent auto-learning batch for this app session only.
    func undoLatestLearning() async {
        guard let batch = latestLearningUndo else { return }
        do {
            for change in batch.changes.reversed() {
                switch change {
                case .created(let id):
                    try await database.deleteDictionaryTerm(id: id)
                case .modified(let before):
                    try await database.updateDictionaryEntry(
                        id: before.id,
                        canonicalTerm: before.canonicalTerm,
                        spokenAliases: before.spokenAliases,
                        kind: before.kind,
                        pinnedPriority: before.pinnedPriority,
                        isEnabled: before.isEnabled,
                        appBundleID: before.appBundleID,
                        source: before.source,
                        updatedAt: before.updatedAt
                    )
                }
            }
            entries = try await database.dictionaryEntries()
            clearLearningUndo()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearLearningUndo() {
        latestLearningUndo = nil
        learnedNotice = nil
    }

    private static func normalizedCorrections(
        _ corrections: [CorrectionCandidate]
    ) -> [CorrectionCandidate] {
        var seen: Set<String> = []
        return corrections.compactMap { correction in
            let original = correction.original.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let replacement = correction.replacement.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !original.isEmpty,
                  !replacement.isEmpty,
                  original != replacement
            else {
                return nil
            }
            let key = folded(original) + "\u{0}" + folded(replacement)
            guard seen.insert(key).inserted else { return nil }
            return CorrectionCandidate(original: original, replacement: replacement)
        }
    }

    private static func deduplicatedAliases(
        _ aliases: [String],
        excluding canonicalTerm: String
    ) -> [String] {
        var seen: Set<String> = []
        let canonicalKey = folded(canonicalTerm)
        return aliases.compactMap { rawAlias in
            let alias = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = folded(alias)
            guard !alias.isEmpty, key != canonicalKey, seen.insert(key).inserted else {
                return nil
            }
            return alias
        }
    }

    private static func folded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func learningNotice(for corrections: [CorrectionCandidate]) -> String {
        if corrections.count == 1, let correction = corrections.first {
            return "Learned \(correction.original) → \(correction.replacement)"
        }
        return "Learned \(corrections.count) corrections"
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
