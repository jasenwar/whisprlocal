import Foundation

enum AudioInputMode: String, CaseIterable, Identifiable, Sendable {
    case fastStart
    case systemDefault

    var id: Self { self }

    var title: String {
        switch self {
        case .fastStart:
            "Fast Start (Mac microphone)"
        case .systemDefault:
            "System Default"
        }
    }

    var detail: String {
        switch self {
        case .fastStart:
            "Uses the Mac’s built-in microphone for near-instant capture. AirPods can still be used for audio output."
        case .systemDefault:
            "Follows macOS Sound settings, including an AirPods microphone. Bluetooth microphones may need a brief warm-up."
        }
    }
}
