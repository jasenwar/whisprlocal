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
            let expansion = multilineBlockExpansion(
                in: expanded,
                triggerRange: range,
                replacement: snippet.replacement
            )
            expanded.replaceSubrange(expansion.range, with: expansion.text)
        }
        return expanded
    }

    /// A multiline replacement is an exact text block when its trigger ends
    /// the transcript. Cleanup models commonly append sentence punctuation to
    /// the trigger or turn the preceding boundary into a comma. Move that
    /// punctuation to the prose before the block instead of leaking it into
    /// the replacement.
    private static func multilineBlockExpansion(
        in text: String,
        triggerRange: Range<String.Index>,
        replacement: String
    ) -> (range: Range<String.Index>, text: String) {
        guard replacement.contains(where: \.isNewline) else {
            return (triggerRange, replacement)
        }

        let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "…"]
        let suffix = text[triggerRange.upperBound...]
        guard suffix.allSatisfy({
            $0.isWhitespace || trailingPunctuation.contains($0)
        }) else {
            return (triggerRange, replacement)
        }

        var lowerBound = triggerRange.lowerBound
        while lowerBound > text.startIndex {
            let previous = text.index(before: lowerBound)
            let character = text[previous]
            guard character.isWhitespace, !character.isNewline else { break }
            lowerBound = previous
        }

        guard lowerBound > text.startIndex else {
            return (lowerBound..<text.endIndex, replacement)
        }

        let previous = text.index(before: lowerBound)
        let precedingCharacter = text[previous]
        let connectorPunctuation: Set<Character> = [",", ";", ":", "-", "–", "—"]
        let sentencePunctuation: Set<Character> = [".", "!", "?", "…"]
        var boundary = ""

        if precedingCharacter.isNewline {
            boundary = ""
        } else if connectorPunctuation.contains(precedingCharacter) {
            lowerBound = previous
            boundary = "."
        } else if sentencePunctuation.contains(precedingCharacter) {
            boundary = ""
        } else {
            boundary = "."
        }

        if !precedingCharacter.isNewline,
           replacement.first?.isNewline != true {
            boundary += "\n"
        }

        return (
            lowerBound..<text.endIndex,
            boundary + replacement
        )
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
