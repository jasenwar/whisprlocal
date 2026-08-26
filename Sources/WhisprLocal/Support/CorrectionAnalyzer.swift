import Foundation

enum CorrectionAnalyzer {
    private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from",
        "had", "has", "have", "he", "her", "his", "i", "in", "is", "it", "its",
        "me", "my", "not", "of", "on", "or", "our", "she", "so", "that", "the",
        "their", "them", "they", "this", "to", "was", "we", "were", "with", "you",
        "your"
    ]

    static func candidates(raw: String, corrected: String) -> [CorrectionCandidate] {
        let rawWords = lexicalWords(raw)
        let correctedWords = lexicalWords(corrected)
        var seen: Set<String> = []
        return alignedSubstitutions(rawWords, correctedWords).compactMap {
            original,
            replacement in
            let originalKey = original.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            let replacementKey = replacement.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            let isCaseOnly = originalKey == replacementKey
            guard original != replacement,
                  !stopwords.contains(originalKey),
                  !stopwords.contains(replacementKey),
                  (!isCaseOnly || usefulCanonicalCapitalization(replacement)),
                  plausibleLexicalChange(original, replacement)
            else {
                return nil
            }
            let key = originalKey + "\u{0}" + replacementKey
            guard seen.insert(key).inserted else { return nil }
            return CorrectionCandidate(
                original: original,
                replacement: replacement
            )
        }
    }

    static func diff(raw: String, corrected: String) -> [WordDiff] {
        let old = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = corrected.split(whereSeparator: \.isWhitespace).map(String.init)
        let table = longestCommonSubsequenceTable(old, new)
        var i = old.count
        var j = new.count
        var result: [WordDiff] = []

        while i > 0 || j > 0 {
            if i > 0, j > 0, old[i - 1] == new[j - 1] {
                result.append(WordDiff(text: old[i - 1], kind: .unchanged))
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || table[i][j - 1] >= table[i - 1][j] {
                result.append(WordDiff(text: new[j - 1], kind: .inserted))
                j -= 1
            } else {
                result.append(WordDiff(text: old[i - 1], kind: .removed))
                i -= 1
            }
        }
        return result.reversed()
    }

    private static func lexicalWords(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
    }

    private static func plausibleLexicalChange(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.caseInsensitiveCompare(rhs) == .orderedSame { return true }
        let distance = levenshtein(lhs.lowercased(), rhs.lowercased())
        return distance <= max(2, min(lhs.count, rhs.count) / 3)
    }

    private static func usefulCanonicalCapitalization(_ value: String) -> Bool {
        let letters = value.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        return letters.allSatisfy(\.isUppercase)
            || value.dropFirst().contains(where: \.isUppercase)
    }

    private static func alignedSubstitutions(
        _ lhs: [String],
        _ rhs: [String]
    ) -> [(String, String)] {
        var table = Array(
            repeating: Array(repeating: 0, count: rhs.count + 1),
            count: lhs.count + 1
        )
        for i in 0...lhs.count { table[i][0] = i }
        for j in 0...rhs.count { table[0][j] = j }
        guard !lhs.isEmpty, !rhs.isEmpty else { return [] }

        for i in 1...lhs.count {
            for j in 1...rhs.count {
                let equal = lhs[i - 1].caseInsensitiveCompare(rhs[j - 1])
                    == .orderedSame
                table[i][j] = min(
                    table[i - 1][j] + 1,
                    table[i][j - 1] + 1,
                    table[i - 1][j - 1] + (equal ? 0 : 1)
                )
            }
        }

        var i = lhs.count
        var j = rhs.count
        var substitutions: [(String, String)] = []
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let equal = lhs[i - 1].caseInsensitiveCompare(rhs[j - 1])
                    == .orderedSame
                let cost = equal ? 0 : 1
                if table[i][j] == table[i - 1][j - 1] + cost {
                    if !equal || lhs[i - 1] != rhs[j - 1] {
                        substitutions.append((lhs[i - 1], rhs[j - 1]))
                    }
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0, table[i][j] == table[i - 1][j] + 1 {
                i -= 1
            } else if j > 0 {
                j -= 1
            }
        }
        return substitutions.reversed()
    }

    private static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1]
            for (j, right) in b.enumerated() {
                current.append(min(
                    min(current[j] + 1, previous[j + 1] + 1),
                    previous[j] + (left == right ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous.last ?? 0
    }

    private static func longestCommonSubsequenceTable(_ lhs: [String], _ rhs: [String]) -> [[Int]] {
        var table = Array(
            repeating: Array(repeating: 0, count: rhs.count + 1),
            count: lhs.count + 1
        )
        guard !lhs.isEmpty, !rhs.isEmpty else { return table }
        for i in 1...lhs.count {
            for j in 1...rhs.count {
                table[i][j] = lhs[i - 1] == rhs[j - 1]
                    ? table[i - 1][j - 1] + 1
                    : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return table
    }
}
