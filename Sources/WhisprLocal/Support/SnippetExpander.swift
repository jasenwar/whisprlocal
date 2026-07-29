import Foundation

enum SnippetExpander {
    static func expand(_ text: String, snippets: [Snippet]) -> String {
        let ordered = snippets.sorted {
            $0.trigger.count == $1.trigger.count
                ? $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending
                : $0.trigger.count > $1.trigger.count
        }

        return ordered.reduce(text) { result, snippet in
            guard !snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return result
            }
            let escaped = NSRegularExpression.escapedPattern(for: snippet.trigger)
            let pattern = #"(?<![\p{L}\p{N}\p{M}])\#(escaped)(?![\p{L}\p{N}\p{M}])"#
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .useUnicodeWordBoundaries]
            ) else {
                return result
            }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            return expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: snippet.replacement)
            )
        }
    }
}
