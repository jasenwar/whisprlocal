import Foundation

protocol TranscriptionEngine: Sendable {
    func transcribe(
        samples: [Float],
        sampleRate: Int,
        hotwords: [String]
    ) async throws -> Transcript

    func prewarm() async
    func releaseIfIdle() async
}

protocol CleanupEngine: Sendable {
    func correct(text: String, dictionary: [String]) async throws -> String
    func prewarm() async
    func abortPendingWork() async
    func shutdown() async
}

extension CleanupEngine {
    func prewarm() async {}
    func abortPendingWork() async {}
    func shutdown() async {}
}

enum WhisprLocalError: LocalizedError {
    case microphoneDenied
    case accessibilityDenied
    case recordingTooShort
    case noSpeech
    case modelMissing
    case modelInvalid(String)
    case transcriptionFailed
    case cleanupTimedOut
    case cleanupModelMissing
    case cleanupRuntimeUnavailable
    case pasteFailed

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone permission is required."
        case .accessibilityDenied: "Accessibility permission is required to paste."
        case .recordingTooShort: "Recording was too short."
        case .noSpeech: "No speech was detected."
        case .modelMissing: "Parakeet model is not installed."
        case .modelInvalid(let reason): "Parakeet model is invalid: \(reason)"
        case .transcriptionFailed: "Local transcription failed."
        case .cleanupTimedOut: "Local cleanup timed out."
        case .cleanupModelMissing: "The local cleanup model is not installed."
        case .cleanupRuntimeUnavailable: "The local cleanup runtime could not start."
        case .pasteFailed: "Could not paste into the target application."
        }
    }
}
