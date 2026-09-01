import Foundation

protocol TranscriptionEngine: Sendable {
    func transcribe(
        samples: [Float],
        sampleRate: Int,
        hotwords: [String]
    ) async throws -> Transcript

    func transcribe(
        samples: [Float],
        sampleRate: Int,
        hotwordPhrases: [HotwordPhrase]
    ) async throws -> Transcript

    func prewarm() async
    func releaseIfIdle() async
}

extension TranscriptionEngine {
    func transcribe(
        samples: [Float],
        sampleRate: Int,
        hotwordPhrases: [HotwordPhrase]
    ) async throws -> Transcript {
        try await transcribe(
            samples: samples,
            sampleRate: sampleRate,
            hotwords: hotwordPhrases.map(\.text)
        )
    }
}

protocol CleanupEngine: Sendable {
    func correct(text: String, dictionary: [String]) async throws -> String
    func correct(
        text: String,
        dictionary: [String],
        context: DictationContext?
    ) async throws -> String
    func prewarm() async
    func abortPendingWork() async
    func shutdown() async
    func lastEngineIdentifier() async -> String
}

extension CleanupEngine {
    func correct(
        text: String,
        dictionary: [String],
        context: DictationContext?
    ) async throws -> String {
        try await correct(text: text, dictionary: dictionary)
    }

    func prewarm() async {}
    func abortPendingWork() async {}
    func shutdown() async {}
    func lastEngineIdentifier() async -> String { "Cleanup" }
}

enum WhisprLocalError: LocalizedError {
    case microphoneDenied
    case microphoneUnavailable
    case accessibilityDenied
    case recordingTooShort
    case noSpeech
    case modelMissing
    case modelInvalid(String)
    case transcriptionFailed
    case transcriptionTimedOut
    case cleanupTimedOut
    case cleanupModelMissing
    case cleanupRuntimeUnavailable
    case pasteFailed

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone permission is required."
        case .microphoneUnavailable:
            "The microphone connected but did not deliver audio. Try the Mac microphone or check Sound settings."
        case .accessibilityDenied: "Accessibility permission is required to paste."
        case .recordingTooShort: "Recording was too short."
        case .noSpeech: "No speech was detected."
        case .modelMissing: "Parakeet model is not installed."
        case .modelInvalid(let reason): "Parakeet model is invalid: \(reason)"
        case .transcriptionFailed: "Local transcription failed."
        case .transcriptionTimedOut: "Groq transcription timed out."
        case .cleanupTimedOut: "Local cleanup timed out."
        case .cleanupModelMissing: "The local cleanup model is not installed."
        case .cleanupRuntimeUnavailable: "The local cleanup runtime could not start."
        case .pasteFailed: "Could not paste into the target application."
        }
    }
}
