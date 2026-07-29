import Foundation

struct DictationStateMachine: Sendable {
    private(set) var state: DictationState = .idle

    mutating func transition(to next: DictationState) throws {
        guard Self.allows(from: state, to: next) else {
            throw StateTransitionError.invalid(from: state, to: next)
        }
        state = next
    }

    static func allows(from current: DictationState, to next: DictationState) -> Bool {
        switch (current, next) {
        case (.idle, .listening),
             (.listening, .transcribing),
             (.listening, .cancelled),
             (.transcribing, .correcting),
             (.transcribing, .cancelled),
             (.correcting, .pasting),
             (.correcting, .succeeded),
             (.correcting, .cancelled),
             (.pasting, .succeeded),
             (.pasting, .cancelled),
             (.succeeded, .idle),
             (.cancelled, .idle):
            return true
        case (_, .failed):
            return current.isBusy
        case (.failed, .idle):
            return true
        default:
            return false
        }
    }
}

enum StateTransitionError: LocalizedError {
    case invalid(from: DictationState, to: DictationState)

    var errorDescription: String? {
        switch self {
        case .invalid(let from, let to):
            "Invalid dictation transition from \(from.label) to \(to.label)."
        }
    }
}
