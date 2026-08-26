import Foundation

struct HotwordPhrase: Sendable, Equatable {
    let text: String
    let score: Double?

    init(_ text: String, score: Double? = nil) {
        self.text = text
        self.score = score
    }
}

struct HotwordEncodingResult: Sendable, Equatable {
    let serialized: String
    let acceptedPhrases: [HotwordPhrase]
    let droppedPhrases: [HotwordPhrase]

    var acceptedCount: Int { acceptedPhrases.count }
    var droppedCount: Int { droppedPhrases.count }
}

struct HotwordEncoder: Sendable {
    private let vocabulary: [String]

    init(tokensFile: String) throws {
        let contents = try String(contentsOfFile: tokensFile, encoding: .utf8)
        self.init(vocabulary: Set(contents.split(separator: "\n").compactMap { line in
            line.split(separator: " ", maxSplits: 1).first.map(String.init)
        }))
    }

    init(vocabulary: Set<String>) {
        self.vocabulary = vocabulary
            .map(\.precomposedStringWithCanonicalMapping)
            .filter { !$0.isEmpty }
            .sorted {
                if $0.count == $1.count {
                    return $0 < $1
                }
                return $0.count > $1.count
            }
    }

    /// Backward-compatible entry point for the current transcription engine protocol.
    func encode(_ phrases: [String]) -> String {
        encode(phrases.map { HotwordPhrase($0) }).serialized
    }

    func encode(_ phrases: [HotwordPhrase]) -> HotwordEncodingResult {
        var encodedPhrases: [String] = []
        var acceptedPhrases: [HotwordPhrase] = []
        var droppedPhrases: [HotwordPhrase] = []

        for phrase in phrases {
            let normalized = Self.normalize(phrase.text)
            let normalizedPhrase = HotwordPhrase(normalized, score: phrase.score)

            guard !normalized.isEmpty,
                  phrase.score?.isFinite != false,
                  let tokens = encodePhrase(normalized) else {
                droppedPhrases.append(normalizedPhrase)
                continue
            }

            var encoded = tokens.joined(separator: " ")
            if let score = phrase.score {
                encoded += " :\(score)"
            }
            encodedPhrases.append(encoded)
            acceptedPhrases.append(normalizedPhrase)
        }

        return HotwordEncodingResult(
            serialized: encodedPhrases.joined(separator: "/"),
            acceptedPhrases: acceptedPhrases,
            droppedPhrases: droppedPhrases
        )
    }

    private static func normalize(_ phrase: String) -> String {
        phrase
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func encodePhrase(_ normalizedPhrase: String) -> [String]? {
        let sentencePieceText = normalizedPhrase
            .split(separator: " ")
            .map { "▁\($0)" }
            .joined()
        var failedIndices: Set<String.Index> = []

        func search(from index: String.Index) -> [String]? {
            guard index != sentencePieceText.endIndex else { return [] }
            guard !failedIndices.contains(index) else { return nil }

            let remaining = sentencePieceText[index...]
            for token in vocabulary where remaining.hasPrefix(token) {
                let nextIndex = sentencePieceText.index(index, offsetBy: token.count)
                if let suffix = search(from: nextIndex) {
                    return [token] + suffix
                }
            }

            failedIndices.insert(index)
            return nil
        }

        return search(from: sentencePieceText.startIndex)
    }
}
