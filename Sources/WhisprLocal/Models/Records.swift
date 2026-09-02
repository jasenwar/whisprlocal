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

enum DictionaryEntryKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case name
    case acronym
    case product
    case technical
    case general

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name: "Name"
        case .acronym: "Acronym"
        case .product: "Product"
        case .technical: "Technical term"
        case .general: "General"
        }
    }
}

enum DictionaryEntrySource: String, CaseIterable, Codable, Sendable {
    case manual
    case suggestion
    case learnedCorrection
}

/// A preferred spelling and the ways it may be spoken or misheard.
///
/// `term` remains as a compatibility alias for older call sites and database
/// consumers. New code should use `canonicalTerm` to make the intent clear.
struct DictionaryEntry: Identifiable, Equatable, Sendable {
    let id: Int64
    var canonicalTerm: String
    var spokenAliases: [String]
    var kind: DictionaryEntryKind
    var pinnedPriority: Int
    var isEnabled: Bool
    var appBundleID: String?
    var source: DictionaryEntrySource
    var useCount: Int
    var lastUsedAt: Date?
    let createdAt: Date
    var updatedAt: Date

    var term: String {
        get { canonicalTerm }
        set { canonicalTerm = newValue }
    }

    var isPinned: Bool { pinnedPriority > 0 }

    init(
        id: Int64,
        canonicalTerm: String,
        spokenAliases: [String] = [],
        kind: DictionaryEntryKind = .general,
        pinnedPriority: Int = 0,
        isEnabled: Bool = true,
        appBundleID: String? = nil,
        source: DictionaryEntrySource = .manual,
        useCount: Int = 0,
        lastUsedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.canonicalTerm = canonicalTerm
        self.spokenAliases = spokenAliases
        self.kind = kind
        self.pinnedPriority = pinnedPriority
        self.isEnabled = isEnabled
        self.appBundleID = appBundleID
        self.source = source
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    init(id: Int64, term: String, createdAt: Date) {
        self.init(id: id, canonicalTerm: term, createdAt: createdAt)
    }
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

/// A database-confirmed batch of corrections that WhisprLocal learned.
///
/// Keeping the mappings structured lets transient UI show exactly what was
/// added without parsing the longer-lived message used by Dictionary settings.
struct DictionaryLearningEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let corrections: [CorrectionCandidate]

    init(
        id: UUID = UUID(),
        corrections: [CorrectionCandidate]
    ) {
        self.id = id
        self.corrections = corrections
    }

    var title: String { "Added to Dictionary" }

    var detail: String {
        guard let first = corrections.first else { return "" }
        let mapping = "\(first.original) → \(first.replacement)"
        let remaining = corrections.count - 1
        return remaining > 0 ? "\(mapping)  +\(remaining) more" : mapping
    }

    var settingsMessage: String {
        if corrections.count == 1, let correction = corrections.first {
            return "Learned \(correction.original) → \(correction.replacement)"
        }
        return "Learned \(corrections.count) corrections"
    }
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
