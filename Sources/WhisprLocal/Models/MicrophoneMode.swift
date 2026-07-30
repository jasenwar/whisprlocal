import Foundation

enum MicrophoneMode: String, CaseIterable, Identifiable, Sendable {
    case systemDefault
    case builtIn

    var id: Self { self }

    var title: String {
        switch self {
        case .systemDefault:
            "System Default"
        case .builtIn:
            "Mac Microphone"
        }
    }
}
