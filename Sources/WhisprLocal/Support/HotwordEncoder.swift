import Foundation

struct HotwordEncoder: Sendable {
    private let vocabulary: Set<String>

    init(tokensFile: String) throws {
        let contents = try String(contentsOfFile: tokensFile, encoding: .utf8)
        vocabulary = Set(contents.split(separator: "\n").compactMap { line in
            line.split(separator: " ", maxSplits: 1).first.map(String.init)
        })
    }

    init(vocabulary: Set<String>) {
        self.vocabulary = vocabulary
    }

    func encode(_ phrases: [String]) -> String {
        phrases.compactMap(encodePhrase).joined(separator: "\n")
    }

    private func encodePhrase(_ phrase: String) -> String? {
        let words = phrase.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let sentencePieceText = words.map { "▁\($0)" }.joined()
        var remaining = sentencePieceText[...]
        var tokens: [String] = []

        while !remaining.isEmpty {
            var candidate = String(remaining)
            var matched: String?
            while !candidate.isEmpty {
                if vocabulary.contains(candidate) {
                    matched = candidate
                    break
                }
                candidate.removeLast()
            }
            guard let matched else { return nil }
            tokens.append(matched)
            remaining = remaining.dropFirst(matched.count)
        }
        return tokens.joined(separator: " ")
    }
}
