import Foundation

enum DeterministicTranscriptCleanup {
    static func finalize(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            return result
        }

        if let firstLetterIndex = result.firstIndex(where: \.isLetter) {
            let firstLetter = result[firstLetterIndex]
            let uppercase = String(firstLetter).uppercased()
            if String(firstLetter) != uppercase {
                result.replaceSubrange(
                    firstLetterIndex...firstLetterIndex,
                    with: uppercase
                )
            }
        }

        if let last = result.last, last.isLetter || last.isNumber {
            result.append(".")
        }
        return result
    }
}
