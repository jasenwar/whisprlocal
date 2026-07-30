import Foundation
import Observation

enum OverlayPosition: String, CaseIterable, Identifiable, Sendable {
    case topLeft
    case topCenter
    case topRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    var id: Self { self }

    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topCenter: "Top Center"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomCenter: "Bottom Center"
        case .bottomRight: "Bottom Right"
        }
    }
}

@MainActor
@Observable
final class AppPreferences {
    private enum Key {
        static let autoPaste = "autoPaste"
        static let keepLastDictationOnClipboard = "keepLastDictationOnClipboard"
        static let sounds = "sounds"
        static let pauseMediaDuringDictation = "pauseMediaDuringDictation"
        static let cleanupEnabled = "cleanupEnabled"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let overlayPosition = "overlayPosition"
        static let audioInputMode = "audioInputMode"
        static let didShowCleanupWarning = "didShowCleanupWarning"
    }

    private let defaults: UserDefaults

    var autoPaste: Bool {
        didSet { defaults.set(autoPaste, forKey: Key.autoPaste) }
    }

    var keepLastDictationOnClipboard: Bool {
        didSet {
            defaults.set(
                keepLastDictationOnClipboard,
                forKey: Key.keepLastDictationOnClipboard
            )
        }
    }

    var sounds: Bool {
        didSet { defaults.set(sounds, forKey: Key.sounds) }
    }

    var pauseMediaDuringDictation: Bool {
        didSet {
            defaults.set(
                pauseMediaDuringDictation,
                forKey: Key.pauseMediaDuringDictation
            )
        }
    }

    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Key.cleanupEnabled) }
    }

    var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }

    var overlayPosition: OverlayPosition {
        didSet { defaults.set(overlayPosition.rawValue, forKey: Key.overlayPosition) }
    }

    var audioInputMode: AudioInputMode {
        didSet { defaults.set(audioInputMode.rawValue, forKey: Key.audioInputMode) }
    }

    var didShowCleanupWarning: Bool {
        didSet { defaults.set(didShowCleanupWarning, forKey: Key.didShowCleanupWarning) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.autoPaste: true,
            Key.keepLastDictationOnClipboard: true,
            Key.sounds: true,
            Key.pauseMediaDuringDictation: true,
            Key.cleanupEnabled: true,
            Key.showMenuBarIcon: false,
            Key.overlayPosition: OverlayPosition.topCenter.rawValue,
            Key.audioInputMode: AudioInputMode.fastStart.rawValue,
            Key.didShowCleanupWarning: false
        ])
        autoPaste = defaults.bool(forKey: Key.autoPaste)
        keepLastDictationOnClipboard = defaults.bool(
            forKey: Key.keepLastDictationOnClipboard
        )
        sounds = defaults.bool(forKey: Key.sounds)
        pauseMediaDuringDictation = defaults.bool(
            forKey: Key.pauseMediaDuringDictation
        )
        cleanupEnabled = defaults.bool(forKey: Key.cleanupEnabled)
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        overlayPosition = OverlayPosition(
            rawValue: defaults.string(forKey: Key.overlayPosition) ?? ""
        ) ?? .topCenter
        audioInputMode = AudioInputMode(
            rawValue: defaults.string(forKey: Key.audioInputMode) ?? ""
        ) ?? .fastStart
        didShowCleanupWarning = defaults.bool(forKey: Key.didShowCleanupWarning)
    }
}
