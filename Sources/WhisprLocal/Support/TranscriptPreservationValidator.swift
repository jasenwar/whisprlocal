import Foundation

struct TranscriptPreservationAssessment: Equatable, Sendable {
    enum RejectionReason: String, Equatable, Sendable {
        case negationChanged = "negation_changed"
        case sentenceCountDropped = "sentence_count_dropped"
        case tokenRetentionTooLow = "token_retention_too_low"
    }

    let rejectionReason: RejectionReason?
    let originalSentenceCount: Int
    let cleanedSentenceCount: Int
    let originalSignificantTokenCount: Int
    let retainedSignificantTokenCount: Int
    let missingSignificantTokenCount: Int
    let retainedTokenRatio: Double
    let containsCorrectionMarker: Bool
    let originalNegationCount: Int
    let cleanedNegationCount: Int

    var isAccepted: Bool { rejectionReason == nil }
}

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

    private static let negationTokens: Set<String> = [
        "no", "not", "never", "without", "cannot", "cant", "couldnt",
        "didnt", "doesnt", "dont", "hadnt", "hasnt", "havent", "isnt",
        "mustnt", "shouldnt", "wasnt", "werent", "wont", "wouldnt",
    ]

    static func validate(
        original: String,
        cleaned: String
    ) throws {
        guard assess(original: original, cleaned: cleaned).isAccepted else {
            throw LocalCleanupValidationError.meaningChanged
        }
    }

    static func assess(
        original: String,
        cleaned: String
    ) -> TranscriptPreservationAssessment {
        let originalSentenceCount = explicitSentenceCount(in: original)
        let cleanedSentenceCount = explicitSentenceCount(in: cleaned)

        let normalizedOriginal = " "
            + original.lowercased()
                .map { $0.isLetter ? $0 : " " }
                .reduce(into: "") { $0.append($1) }
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            + " "
        let containsCorrectionMarker = correctionMarkers.contains(where: {
            normalizedOriginal.contains($0)
        })

        let originalTokens = significantTokens(
            in: SpokenTimeNormalizer.normalize(original)
        )
        let cleanedTokens = significantTokens(
            in: SpokenTimeNormalizer.normalize(cleaned)
        )
        let retainedCount = originalTokens.intersection(cleanedTokens).count
        let missingCount = originalTokens.count - retainedCount
        let retainedRatio = originalTokens.isEmpty
            ? 1
            : Double(retainedCount) / Double(originalTokens.count)

        let sentenceCountDropped =
            cleanedSentenceCount < originalSentenceCount
        let highConfidenceSentenceMerge =
            missingCount <= 1 && retainedRatio >= 0.95
        let tokenRetentionTooLow =
            originalTokens.count >= 5
            && missingCount >= 2
            && retainedRatio < 0.8
        let originalNegationCount = negationCount(in: original)
        let cleanedNegationCount = negationCount(in: cleaned)
        let negationChanged = originalNegationCount != cleanedNegationCount

        let rejectionReason:
            TranscriptPreservationAssessment.RejectionReason?
        if !containsCorrectionMarker, negationChanged {
            rejectionReason = .negationChanged
        } else if !containsCorrectionMarker,
           sentenceCountDropped,
           !highConfidenceSentenceMerge {
            rejectionReason = .sentenceCountDropped
        } else if !containsCorrectionMarker, tokenRetentionTooLow {
            rejectionReason = .tokenRetentionTooLow
        } else {
            rejectionReason = nil
        }

        return TranscriptPreservationAssessment(
            rejectionReason: rejectionReason,
            originalSentenceCount: originalSentenceCount,
            cleanedSentenceCount: cleanedSentenceCount,
            originalSignificantTokenCount: originalTokens.count,
            retainedSignificantTokenCount: retainedCount,
            missingSignificantTokenCount: missingCount,
            retainedTokenRatio: retainedRatio,
            containsCorrectionMarker: containsCorrectionMarker,
            originalNegationCount: originalNegationCount,
            cleanedNegationCount: cleanedNegationCount
        )
    }

    private static func negationCount(in text: String) -> Int {
        lexicalTokens(in: text)
            .count(where: negationTokens.contains)
    }

    private static func significantTokens(in text: String) -> Set<String> {
        Set(lexicalTokens(in: text).filter {
            !ignoredTokens.contains($0) && !negationTokens.contains($0)
        })
    }

    private static func lexicalTokens(in text: String) -> [String] {
        text.lowercased()
            .split {
                !$0.isLetter && !$0.isNumber && $0 != "_"
                    && $0 != "'" && $0 != "’"
            }
            .map {
                String($0.filter { $0 != "'" && $0 != "’" })
            }
            .filter { !$0.isEmpty }
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
