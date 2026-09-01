import Foundation

/// Finds dictionary-safe corrections made after WhisprLocal pastes a transcript.
///
/// This deliberately has a narrower contract than `CorrectionAnalyzer`: a post-paste
/// edit can include ordinary writing changes, so this analyzer only returns compact,
/// unambiguous word or phrase mappings suitable for learning a spoken alias.
enum PostPasteCorrectionLearningAnalyzer: Sendable {
    /// Returns deduplicated `spoken alias -> preferred spelling` mappings.
    ///
    /// The result is deterministic and contains no mapping when the edit includes a
    /// changed sensitive syntax, a non-grammar insertion/deletion, or a large rewrite.
    static func mappings(pasted: String, edited: String) -> [CorrectionCandidate] {
        // Sensitive content may be present elsewhere in a sentence. It is safe to
        // ignore only when the sensitive fragment is unchanged; any edit to it fails closed.
        guard unsafeFragments(in: pasted) == unsafeFragments(in: edited) else {
            return []
        }

        let pastedWords = safeLexicalWords(in: pasted)
        let editedWords = safeLexicalWords(in: edited)
        guard !pastedWords.isEmpty,
              !editedWords.isEmpty,
              pastedWords.count <= maximumWords,
              editedWords.count <= maximumWords,
              !looksLikeCommand(pastedWords),
              !looksLikeCommand(editedWords)
        else {
            return []
        }

        let edits = alignment(from: pastedWords, to: editedWords)
        let blocks = changedBlocks(in: edits)
        let phraseMatches = blocks.map(bestPhraseMatch)
        let changedCount = zip(blocks, phraseMatches).reduce(into: 0) {
            count,
            pair in
            let (block, phraseMatch) = pair
            if let phraseMatch {
                count += block.count - phraseMatch.range.count + 1
            } else {
                count += block.count
            }
        }
        let longestText = max(pastedWords.count, editedWords.count)
        let maximumChanges = max(4, min(8, (longestText / 2) + 1))
        guard changedCount <= maximumChanges else { return [] }

        // Retain the existing lexical-distance and stop-word heuristics, then apply
        // the stricter post-paste safety checks below.
        let baselineCandidates = Set(
            CorrectionAnalyzer.candidates(raw: pasted, corrected: edited)
                .map { mappingKey(original: $0.original, replacement: $0.replacement) }
        )

        var mappings: [CorrectionCandidate] = []
        var seen: Set<String> = []
        for (block, phraseMatch) in zip(blocks, phraseMatches) {
            if let phrase = phraseMatch?.candidate {
                let key = mappingKey(
                    original: phrase.original,
                    replacement: phrase.replacement
                )
                if seen.insert(key).inserted {
                    mappings.append(phrase)
                }
            }

            for (index, edit) in block.enumerated() {
                guard phraseMatch?.range.contains(index) != true else { continue }
                switch oneWordDecision(
                    from: edit,
                    baselineCandidates: baselineCandidates
                ) {
                case .ignored:
                    continue
                case .rejected:
                    return []
                case .candidate(let candidate):
                    let key = mappingKey(
                        original: candidate.original,
                        replacement: candidate.replacement
                    )
                    if seen.insert(key).inserted {
                        mappings.append(candidate)
                    }
                }
            }
        }

        return mappings.count <= maximumMappings ? mappings : []
    }

    /// Convenience spelling for callers that present these as correction candidates.
    static func candidates(pasted: String, edited: String) -> [CorrectionCandidate] {
        mappings(pasted: pasted, edited: edited)
    }

    private static let maximumWords = 80
    private static let maximumMappings = 3
    private static let maximumPhraseWords = 4

    private static let grammarWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "being", "but", "by",
        "can", "did", "do", "does", "for", "from", "had", "has", "have", "he", "her",
        "here", "him", "his", "i", "if", "in", "is", "it", "its", "me", "my", "no",
        "not", "of", "on", "or", "our", "please", "re", "s", "she", "so", "that", "the",
        "their", "them", "then", "there", "they", "this", "to", "was", "we", "were", "with",
        "would", "you", "your"
    ]

    private static let commandStarters: Set<String> = [
        "brew", "cd", "chmod", "chown", "curl", "docker", "git", "kill", "ls", "mv", "npm",
        "pip", "python", "rm", "run", "scp", "ssh", "sudo", "swift", "xcodebuild"
    ]

    private enum Edit {
        case unchanged
        case insertion(String)
        case deletion(String)
        case substitution(String, String)

        var isUnchanged: Bool {
            if case .unchanged = self { return true }
            return false
        }
    }

    private enum OneWordDecision {
        case ignored
        case candidate(CorrectionCandidate)
        case rejected
    }

    private struct PhraseMatch {
        let candidate: CorrectionCandidate
        let range: Range<Int>
    }

    private static func changedBlocks(in edits: [Edit]) -> [[Edit]] {
        var blocks: [[Edit]] = []
        var current: [Edit] = []
        for edit in edits {
            if edit.isUnchanged {
                if !current.isEmpty {
                    blocks.append(current)
                    current = []
                }
            } else {
                current.append(edit)
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    private static func bestPhraseMatch(in block: [Edit]) -> PhraseMatch? {
        var best: PhraseMatch?
        for start in block.indices {
            for end in (start + 1)...block.count {
                let range = start..<end
                guard let candidate = phraseCandidate(from: Array(block[range])) else {
                    continue
                }
                if let best, best.range.count >= range.count {
                    continue
                }
                best = PhraseMatch(candidate: candidate, range: range)
            }
        }
        return best
    }

    private static func phraseCandidate(
        from block: [Edit]
    ) -> CorrectionCandidate? {
        var original: [String] = []
        var replacement: [String] = []
        for edit in block {
            switch edit {
            case .unchanged:
                return nil
            case .insertion(let word):
                replacement.append(word)
            case .deletion(let word):
                original.append(word)
            case .substitution(let old, let new):
                original.append(old)
                replacement.append(new)
            }
        }

        guard original.count >= 1,
              replacement.count >= 1,
              original.count <= maximumPhraseWords,
              replacement.count <= maximumPhraseWords,
              original.count > 1 || replacement.count > 1,
              original.allSatisfy(isSafePhraseWord),
              replacement.allSatisfy(isSafePhraseWord)
        else {
            return nil
        }

        let originalJoined = folded(original.joined())
        let replacementJoined = folded(replacement.joined())
        let reshaped = original.count != replacement.count
            || originalJoined == replacementJoined
        guard reshaped,
              tightlyRelated(originalJoined, replacementJoined),
              hasCanonicalPhraseStyling(replacement)
        else {
            return nil
        }
        return CorrectionCandidate(
            original: original.joined(separator: " "),
            replacement: replacement.joined(separator: " ")
        )
    }

    private static func oneWordDecision(
        from edit: Edit,
        baselineCandidates: Set<String>
    ) -> OneWordDecision {
        switch edit {
        case .unchanged:
            return .ignored
        case .insertion(let word), .deletion(let word):
            // Small article/pronoun changes are common cleanup behavior. Any
            // content-word insertion or deletion makes the alignment ambiguous.
            return grammarWords.contains(folded(word)) ? .ignored : .rejected
        case .substitution(let original, let replacement):
            let originalKey = folded(original)
            let replacementKey = folded(replacement)

            if originalKey == replacementKey {
                // Do not learn sentence capitalization, but retain acronyms and
                // camel case (for example, api -> API or whisprlocal -> WhisprLocal).
                guard hasCanonicalStyling(replacement),
                      baselineCandidates.contains(
                          mappingKey(original: original, replacement: replacement)
                      )
                else {
                    return .ignored
                }
            } else if grammarWords.contains(originalKey), grammarWords.contains(replacementKey) {
                return .ignored
            } else {
                guard isSafeWord(original),
                      isSafeWord(replacement),
                      baselineCandidates.contains(
                          mappingKey(original: original, replacement: replacement)
                      )
                else {
                    return .rejected
                }
            }
            return .candidate(
                CorrectionCandidate(original: original, replacement: replacement)
            )
        }
    }

    private static func lexicalWords(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    private static func safeLexicalWords(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .filter { !isUnsafeFragment(String($0)) }
            .flatMap { lexicalWords(in: String($0)) }
    }

    private static func looksLikeCommand(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        if commandStarters.contains(folded(first)) { return true }
        return zip(words, words.dropFirst()).contains { current, next in
            folded(current) == "run" && commandStarters.contains(folded(next))
        }
    }

    private static func unsafeFragments(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter(isUnsafeFragment)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
    }

    private static func isUnsafeFragment(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .punctuationCharacters)
        guard !trimmed.isEmpty else { return false }
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("www.") || trimmed.contains("@") {
            return true
        }
        let unsafeCharacters = CharacterSet(charactersIn: "\\\\/_`$#[]{}<>|=&;~")
        if trimmed.unicodeScalars.contains(where: { scalar in
            scalar.properties.numericType != nil || unsafeCharacters.contains(scalar)
        }) {
            return true
        }
        let dottedParts = trimmed.split(separator: ".", omittingEmptySubsequences: true)
        return dottedParts.count >= 2 && dottedParts.allSatisfy { $0.allSatisfy(\.isLetter) }
    }

    private static func isSafeWord(_ word: String) -> Bool {
        let key = folded(word)
        guard !grammarWords.contains(key),
              word.count >= 2,
              word.count <= 48,
              word.allSatisfy(\.isLetter)
        else {
            return false
        }
        return true
    }

    private static func isSafePhraseWord(_ word: String) -> Bool {
        !grammarWords.contains(folded(word))
            && word.count <= 48
            && word.allSatisfy(\.isLetter)
    }

    private static func hasCanonicalStyling(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        return letters.allSatisfy(\.isUppercase)
            || word.dropFirst().contains(where: \.isUppercase)
    }

    private static func hasCanonicalPhraseStyling(_ words: [String]) -> Bool {
        if words.count == 1, let word = words.first {
            return hasCanonicalStyling(word)
        }
        return words.allSatisfy { word in
            word.first?.isUppercase == true
        }
    }

    private static func tightlyRelated(_ lhs: String, _ rhs: String) -> Bool {
        let shortest = min(lhs.count, rhs.count)
        guard shortest >= 2 else { return false }
        return levenshtein(lhs, rhs) <= max(1, shortest / 8)
    }

    private static func folded(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func mappingKey(original: String, replacement: String) -> String {
        folded(original) + "\u{0}" + folded(replacement)
    }

    private static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous.last ?? 0
    }

    private static func alignment(from source: [String], to target: [String]) -> [Edit] {
        var table = Array(
            repeating: Array(repeating: 0, count: target.count + 1),
            count: source.count + 1
        )
        for index in 0...source.count { table[index][0] = index }
        for index in 0...target.count { table[0][index] = index }

        guard !source.isEmpty, !target.isEmpty else { return [] }
        for sourceIndex in 1...source.count {
            for targetIndex in 1...target.count {
                let replacementCost = folded(source[sourceIndex - 1]) == folded(target[targetIndex - 1]) ? 0 : 1
                table[sourceIndex][targetIndex] = min(
                    table[sourceIndex - 1][targetIndex] + 1,
                    table[sourceIndex][targetIndex - 1] + 1,
                    table[sourceIndex - 1][targetIndex - 1] + replacementCost
                )
            }
        }

        var sourceIndex = source.count
        var targetIndex = target.count
        var result: [Edit] = []
        while sourceIndex > 0 || targetIndex > 0 {
            if sourceIndex > 0, targetIndex > 0 {
                let sourceWord = source[sourceIndex - 1]
                let targetWord = target[targetIndex - 1]
                let sameWord = folded(sourceWord) == folded(targetWord)
                let diagonalCost = sameWord ? 0 : 1
                if table[sourceIndex][targetIndex] == table[sourceIndex - 1][targetIndex - 1] + diagonalCost {
                    result.append(
                        sameWord && sourceWord == targetWord
                            ? .unchanged
                            : .substitution(sourceWord, targetWord)
                    )
                    sourceIndex -= 1
                    targetIndex -= 1
                    continue
                }
            }

            if sourceIndex > 0, table[sourceIndex][targetIndex] == table[sourceIndex - 1][targetIndex] + 1 {
                result.append(.deletion(source[sourceIndex - 1]))
                sourceIndex -= 1
            } else if targetIndex > 0 {
                result.append(.insertion(target[targetIndex - 1]))
                targetIndex -= 1
            }
        }
        return result.reversed()
    }
}

/// A concise name for the post-paste learning gate used by future call sites.
typealias CorrectionLearningAnalyzer = PostPasteCorrectionLearningAnalyzer
