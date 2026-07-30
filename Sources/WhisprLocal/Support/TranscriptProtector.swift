import Foundation

struct ProtectedTranscript: Sendable {
    let text: String
    let replacements: [String: String]

    func restore(_ output: String) throws -> String {
        let placeholderPattern = #"\[\[PROTECTED_\d{4}\]\]"#
        let regex = try NSRegularExpression(pattern: placeholderPattern)
        let range = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, range: range)

        var counts: [String: Int] = [:]
        for match in matches {
            guard let swiftRange = Range(match.range, in: output) else {
                continue
            }
            counts[String(output[swiftRange]), default: 0] += 1
        }

        for (placeholder, count) in counts {
            guard replacements[placeholder] != nil, count == 1 else {
                throw LocalCleanupValidationError.invalidPlaceholder
            }
        }
        guard counts.count == replacements.count,
              replacements.keys.allSatisfy({ counts[$0] == 1 })
        else {
            throw LocalCleanupValidationError.invalidPlaceholder
        }

        var restored = output
        for (placeholder, original) in replacements where counts[placeholder] == 1 {
            restored = restored.replacingOccurrences(of: placeholder, with: original)
        }

        guard !restored.contains("[[PROTECTED_") else {
            throw LocalCleanupValidationError.invalidPlaceholder
        }
        return restored
    }
}

enum TranscriptProtector {
    private static let patterns = [
        #"https?://[^\s<>()]+"#,
        #"\b[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}\b"#,
        #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
        #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}\b"#,
        #"(?:\\\\[^\\\s]+\\[^\\\n]+|[A-Za-z]:\\[^\n]+|(?<!\w)/(?:[^\s/]+/)*[^\s]+)"#,
        #"`[^`\n]+`|```[\s\S]*?```"#,
        #"\$\d+(?:[.,]\d+)*"#,
        #"\b\d{1,2}:\d{2}(?:\s?[APap][Mm])?\b"#,
        #"\bv?\d+\.\d+(?:\.\d+){0,3}\b"#,
        #"\b\d{4}-\d{2}-\d{2}\b"#,
        #"\b\d{7,}\b"#,
        #"\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*|%[A-Za-z_][A-Za-z0-9_]*%"#,
        #"(?<!\w)--?[A-Za-z][A-Za-z0-9-]*\b"#,
        #"\b[\w.-]+\.[A-Za-z0-9]{1,8}\b"#,
        #"\b\d+(?:[.,]\d+)*\b"#
    ]

    static func protect(_ text: String, dictionary: [String]) -> ProtectedTranscript {
        let fullRange = NSRange(text.startIndex..., in: text)
        var candidates: [NSRange] = []

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            candidates.append(
                contentsOf: regex.matches(in: text, range: fullRange).map(\.range)
            )
        }

        for term in dictionary.prefix(250) {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: trimmed)
            let pattern = #"(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"#
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }
            candidates.append(
                contentsOf: regex.matches(in: text, range: fullRange).map(\.range)
            )
        }

        let accepted = nonOverlapping(candidates)
        var protectedText = text
        var replacements: [String: String] = [:]

        for (offset, range) in accepted.enumerated().reversed() {
            guard let swiftRange = Range(range, in: protectedText) else {
                continue
            }
            let placeholder = String(format: "[[PROTECTED_%04d]]", offset + 1)
            replacements[placeholder] = String(protectedText[swiftRange])
            protectedText.replaceSubrange(swiftRange, with: placeholder)
        }

        return ProtectedTranscript(text: protectedText, replacements: replacements)
    }

    private static func nonOverlapping(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .sorted {
                if $0.location == $1.location {
                    return $0.length > $1.length
                }
                return $0.location < $1.location
            }

        var accepted: [NSRange] = []
        for candidate in sorted {
            guard !accepted.contains(where: {
                NSIntersectionRange($0, candidate).length > 0
            }) else {
                continue
            }
            accepted.append(candidate)
        }
        return accepted
    }
}

enum LocalCleanupValidationError: LocalizedError, Sendable {
    case emptyOutput
    case invalidLength
    case invalidPlaceholder
    case unexpectedFormatting
    case invalidResponse
    case invalidModel(String)

    var errorDescription: String? {
        switch self {
        case .emptyOutput: "Local cleanup returned empty text."
        case .invalidLength: "Local cleanup changed the transcript length unexpectedly."
        case .invalidPlaceholder: "Local cleanup changed a protected value."
        case .unexpectedFormatting: "Local cleanup returned commentary or formatting."
        case .invalidResponse: "Local cleanup returned an invalid response."
        case .invalidModel(let reason): "Local cleanup model is invalid: \(reason)"
        }
    }
}
