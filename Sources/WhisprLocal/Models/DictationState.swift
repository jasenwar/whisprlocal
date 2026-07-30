import Foundation

enum DictationState: Equatable, Sendable {
    case idle
    case preparing
    case listening
    case transcribing
    case correcting
    case pasting
    case succeeded
    case cancelled
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .listening, .transcribing, .correcting, .pasting:
            true
        default:
            false
        }
    }

    var label: String {
        switch self {
        case .idle: "Ready"
        case .preparing: "Connecting microphone"
        case .listening: "Listening"
        case .transcribing: "Transcribing"
        case .correcting: "Cleaning up"
        case .pasting: "Pasting"
        case .succeeded: "Pasted"
        case .cancelled: "Cancelled"
        case .failed(let message): message
        }
    }
}

struct Transcript: Equatable, Sendable {
    let text: String
    let engine: String
    let duration: TimeInterval
}
