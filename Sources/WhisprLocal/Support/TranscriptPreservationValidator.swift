import Foundation

enum TranscriptPreservationValidator {
    private static let ignoredTokens: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "being", "but",
        "by", "can", "could", "did", "do", "does", "er", "erm", "for",
        "from", "had", "has", "have", "he", "her", "him", "his", "i", "if",
        "in", "is", "it", "its", "may", "me", "might", "must", "my", "not",
        "of", "on", "or", "our", "she", "should", "than", "that", "the",
        "their", "them", "then", "these", "they", "this", "those", "to", "uh",
        "um", "was", "we", "were", "will", "with", "would", "you", "your",
    ]

    private static let correctionMarkers = [
        " actually make that ",
        " correction ",
        " i mean ",
        " make that ",
        " no wait ",
        " or rather ",
    ]

    static func validate(
        original: String,
        cleaned: String
    ) throws {
        guard explicitSentenceCount(in: cleaned)
                >= explicitSentenceCount(in: original) else {
            throw LocalCleanupValidationError.meaningChanged
        }

        let normalizedOriginal = " "
            + original.lowercased()
                .map { $0.isLetter ? $0 : " " }
                .reduce(into: "") { $0.append($1) }
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            + " "
        guard !correctionMarkers.contains(where: {
            normalizedOriginal.contains($0)
        }) else {
            return
        }

        let originalTokens = significantTokens(in: original)
        guard originalTokens.count >= 5 else { return }
        let cleanedTokens = significantTokens(in: cleaned)
        let retainedCount = originalTokens.intersection(cleanedTokens).count
        let missingCount = originalTokens.count - retainedCount
        let retainedRatio =
            Double(retainedCount) / Double(originalTokens.count)

        guard missingCount < 2 || retainedRatio >= 0.8 else {
            throw LocalCleanupValidationError.meaningChanged
        }
    }

    private static func significantTokens(in text: String) -> Set<String> {
        Set(
            text.split {
                !$0.isLetter && !$0.isNumber && $0 != "_"
            }
            .map { $0.lowercased() }
            .filter { !ignoredTokens.contains($0) }
        )
    }

    private static func explicitSentenceCount(in text: String) -> Int {
        var count = 0
        var isInsideTerminatorRun = false

        for character in text {
            let isTerminator =
                character == "."
                || character == "!"
                || character == "?"
            if isTerminator, !isInsideTerminatorRun {
                count += 1
            }
            isInsideTerminatorRun = isTerminator
        }
        return count
    }
}
