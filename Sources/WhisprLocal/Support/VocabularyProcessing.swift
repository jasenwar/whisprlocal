import Foundation

struct VocabularyPlan: Sendable {
    let entries: [DictionaryEntry]
    let transcriptionPhrases: [HotwordPhrase]
    let cleanupTerms: [String]
}

enum VocabularyPlanner {
    static let maximumRecognitionPhrases = 64

    static func makePlan(
        entries: [DictionaryEntry],
        snippets: [Snippet],
        targetBundleIdentifier: String?
    ) -> VocabularyPlan {
        let target = targetBundleIdentifier?.lowercased()
        let applicable = entries
            .filter { entry in
                guard entry.isEnabled else { return false }
                guard let scope = entry.appBundleID?.lowercased() else {
                    return true
                }
                guard let target else { return false }
                return scope == target
            }
            .sorted { lhs, rhs in
                if lhs.pinnedPriority != rhs.pinnedPriority {
                    return lhs.pinnedPriority > rhs.pinnedPriority
                }
                let lhsScoped = lhs.appBundleID != nil
                let rhsScoped = rhs.appBundleID != nil
                if lhsScoped != rhsScoped { return lhsScoped }
                if lhs.useCount != rhs.useCount {
                    return lhs.useCount > rhs.useCount
                }
                let lhsUsed = lhs.lastUsedAt ?? .distantPast
                let rhsUsed = rhs.lastUsedAt ?? .distantPast
                if lhsUsed != rhsUsed { return lhsUsed > rhsUsed }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.canonicalTerm.localizedCaseInsensitiveCompare(
                    rhs.canonicalTerm
                ) == .orderedAscending
            }

        let cleanupTerms = deduplicated(
            applicable.map(\.canonicalTerm) + snippets.map(\.trigger)
        )
        var seenRecognition: Set<String> = []
        var recognition: [HotwordPhrase] = []
        for entry in applicable {
            let term = normalized(entry.canonicalTerm)
            guard !term.isEmpty else { continue }
            let key = normalizedKey(term)
            guard seenRecognition.insert(key).inserted else { continue }
            let score = entry.isPinned
                ? min(2.5, 1.5 + Double(entry.pinnedPriority) * 0.5)
                : nil
            recognition.append(HotwordPhrase(term, score: score))
        }
        for snippet in snippets {
            let trigger = normalized(snippet.trigger)
            guard !trigger.isEmpty else { continue }
            let key = normalizedKey(trigger)
            guard seenRecognition.insert(key).inserted else { continue }
            recognition.append(HotwordPhrase(trigger))
        }
        return VocabularyPlan(
            entries: applicable,
            transcriptionPhrases: Array(
                recognition.prefix(maximumRecognitionPhrases)
            ),
            cleanupTerms: cleanupTerms
        )
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let normalized = normalized(value)
            guard !normalized.isEmpty else { return nil }
            let key = normalizedKey(normalized)
            return seen.insert(key).inserted ? normalized : nil
        }
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func normalizedKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive], locale: .current)
    }
}

struct VocabularyResolution: Sendable, Equatable {
    let text: String
    let appliedEntryIDs: [Int64]
}

enum VocabularyResolver {
    private struct Rule {
        let entryID: Int64
        let spokenForm: String
        let canonicalTerm: String
        let rank: Int
    }

    static func resolve(
        _ text: String,
        entries: [DictionaryEntry]
    ) -> VocabularyResolution {
        let input = text.precomposedStringWithCanonicalMapping
        let rules = replacementRules(entries)
        guard !rules.isEmpty else {
            return VocabularyResolution(text: input, appliedEntryIDs: [])
        }

        let alternatives = rules.map { rule in
            rule.spokenForm
                .split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: #"\s+"#)
        }
        let wordLike = #"\p{L}\p{N}\p{M}\p{Pc}"#
        let pattern = #"(?<![\#(wordLike)])(?:"#
            + alternatives.joined(separator: "|")
            + #")(?![\#(wordLike)])"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .useUnicodeWordBoundaries]
        ) else {
            return VocabularyResolution(text: input, appliedEntryIDs: [])
        }

        let range = NSRange(input.startIndex..., in: input)
        let matches = expression.matches(in: input, range: range)
        var output = input
        var applied: Set<Int64> = []
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: output) else {
                continue
            }
            let key = normalizedKey(String(output[swiftRange]))
            guard let rule = rules.first(where: {
                normalizedKey($0.spokenForm) == key
            }) else {
                continue
            }
            output.replaceSubrange(swiftRange, with: rule.canonicalTerm)
            applied.insert(rule.entryID)
        }
        return VocabularyResolution(
            text: output,
            appliedEntryIDs: applied.sorted()
        )
    }

    private static func replacementRules(
        _ entries: [DictionaryEntry]
    ) -> [Rule] {
        var seen: Set<String> = []
        var rules: [Rule] = []
        for (rank, entry) in entries.enumerated() where entry.isEnabled {
            for spoken in [entry.canonicalTerm] + entry.spokenAliases {
                let normalized = spoken
                    .precomposedStringWithCanonicalMapping
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                guard !normalized.isEmpty else { continue }
                let key = normalizedKey(normalized)
                guard seen.insert(key).inserted else { continue }
                rules.append(Rule(
                    entryID: entry.id,
                    spokenForm: normalized,
                    canonicalTerm: entry.canonicalTerm,
                    rank: rank
                ))
            }
        }
        return rules.sorted {
            if $0.spokenForm.count != $1.spokenForm.count {
                return $0.spokenForm.count > $1.spokenForm.count
            }
            return $0.rank < $1.rank
        }
    }

    private static func normalizedKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: .current)
    }
}
