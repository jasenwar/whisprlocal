import Foundation

enum SnippetExpander {
    static func expand(_ text: String, snippets: [Snippet]) -> String {
        let normalizedText = text.precomposedStringWithCanonicalMapping
        let ordered = normalizedSnippets(snippets)
        guard !ordered.isEmpty else { return normalizedText }

        let alternatives = ordered.map { snippet in
            snippet.trigger
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
            return normalizedText
        }

        let fullRange = NSRange(normalizedText.startIndex..., in: normalizedText)
        let matches = expression.matches(in: normalizedText, range: fullRange)
        var expanded = normalizedText

        // Matches are calculated once from the original transcript. Replacing in
        // reverse makes expansion deterministic and prevents replacement text
        // from recursively triggering another snippet.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: expanded) else { continue }
            let key = normalizedKey(String(expanded[range]))
            guard let snippet = ordered.first(where: {
                normalizedKey($0.trigger) == key
            }) else {
                continue
            }
            expanded.replaceSubrange(range, with: snippet.replacement)
        }
        return expanded
    }

    private static func normalizedSnippets(_ snippets: [Snippet]) -> [Snippet] {
        var seen: Set<String> = []
        return snippets.compactMap { snippet -> Snippet? in
            let trigger = snippet.trigger
                .precomposedStringWithCanonicalMapping
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !trigger.isEmpty else { return nil }
            let key = normalizedKey(trigger)
            guard seen.insert(key).inserted else { return nil }
            var normalized = snippet
            normalized.trigger = trigger
            return normalized
        }
        .sorted {
            if $0.trigger.count == $1.trigger.count {
                return $0.trigger.localizedCaseInsensitiveCompare($1.trigger)
                    == .orderedAscending
            }
            return $0.trigger.count > $1.trigger.count
        }
    }

    private static func normalizedKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: .current)
    }
}
