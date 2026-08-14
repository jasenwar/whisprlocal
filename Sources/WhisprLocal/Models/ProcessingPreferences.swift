import Foundation

enum ProcessingMode: String, CaseIterable, Identifiable, Sendable {
    case groqPreferred
    case fullyLocal

    var id: Self { self }

    var title: String {
        switch self {
        case .groqPreferred: "Groq Preferred"
        case .fullyLocal: "Fully Local"
        }
    }

    var detail: String {
        switch self {
        case .groqPreferred:
            "Uses Groq first and falls back to the existing local pipeline when Groq is unavailable or limited."
        case .fullyLocal:
            "Uses Parakeet and local Qwen cleanup. Audio and text never leave this Mac."
        }
    }
}

enum ContextAwarenessLevel: String, CaseIterable, Identifiable, Sendable {
    case off
    case textOnly
    case focusedWindow

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Off"
        case .textOnly: "Text Only"
        case .focusedWindow: "Focused Window"
        }
    }

    var detail: String {
        switch self {
        case .off:
            "No application context is collected."
        case .textOnly:
            "Sends the application name, window title, and selected text when available."
        case .focusedWindow:
            "Also sends a temporary image of only the focused window. The image is never saved."
        }
    }
}

enum GroqTranscriptionModel: String, CaseIterable, Identifiable, Sendable {
    case whisperLargeV3 = "whisper-large-v3"
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"

    var id: Self { self }

    var title: String {
        switch self {
        case .whisperLargeV3: "Whisper Large V3 — accuracy"
        case .whisperLargeV3Turbo: "Whisper Large V3 Turbo — speed"
        }
    }
}

enum GroqCleanupModel: String, CaseIterable, Identifiable, Sendable {
    case gptOSS20B = "openai/gpt-oss-20b"
    case gptOSS120B = "openai/gpt-oss-120b"
    case qwen36 = "qwen/qwen3.6-27b"

    var id: Self { self }

    var title: String {
        switch self {
        case .gptOSS20B: "GPT-OSS 20B — fastest"
        case .gptOSS120B: "GPT-OSS 120B — strongest"
        case .qwen36: "Qwen 3.6 27B"
        }
    }

    var maximumCompletionTokens: Int {
        switch self {
        case .gptOSS20B, .gptOSS120B:
            4_096
        case .qwen36:
            1_024
        }
    }
}

enum GroqContextModel {
    static let recommended = "qwen/qwen3.6-27b"
}
