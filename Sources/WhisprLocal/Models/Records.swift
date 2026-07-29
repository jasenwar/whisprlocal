import Foundation

struct TranscriptionRecord: Identifiable, Equatable, Sendable {
    let id: Int64
    let rawText: String
    let correctedText: String
    let createdAt: Date
    let audioDuration: TimeInterval
    let processingLatency: TimeInterval
    let transcriptionEngine: String
    let cleanupEngine: String
    let status: String
}

struct DictionaryEntry: Identifiable, Equatable, Sendable {
    let id: Int64
    var term: String
    let createdAt: Date
}

struct Snippet: Identifiable, Equatable, Sendable {
    let id: Int64
    var trigger: String
    var replacement: String
    let createdAt: Date
}

struct CorrectionCandidate: Identifiable, Equatable, Sendable {
    let original: String
    let replacement: String

    var id: String { "\(original)\u{0}\(replacement)" }
}

struct WordDiff: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case unchanged
        case removed
        case inserted
    }

    let id = UUID()
    let text: String
    let kind: Kind
}
