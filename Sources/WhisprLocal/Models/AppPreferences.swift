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
        static let sounds = "sounds"
        static let pauseMediaDuringDictation = "pauseMediaDuringDictation"
        static let cleanupEnabled = "cleanupEnabled"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let overlayPosition = "overlayPosition"
        static let didShowCleanupWarning = "didShowCleanupWarning"
    }

    private let defaults: UserDefaults

    var autoPaste: Bool {
        didSet { defaults.set(autoPaste, forKey: Key.autoPaste) }
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

    var didShowCleanupWarning: Bool {
        didSet { defaults.set(didShowCleanupWarning, forKey: Key.didShowCleanupWarning) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.autoPaste: true,
            Key.sounds: true,
            Key.pauseMediaDuringDictation: true,
            Key.cleanupEnabled: true,
            Key.showMenuBarIcon: false,
            Key.overlayPosition: OverlayPosition.topCenter.rawValue,
            Key.didShowCleanupWarning: false
        ])
        autoPaste = defaults.bool(forKey: Key.autoPaste)
        sounds = defaults.bool(forKey: Key.sounds)
        pauseMediaDuringDictation = defaults.bool(
            forKey: Key.pauseMediaDuringDictation
        )
        cleanupEnabled = defaults.bool(forKey: Key.cleanupEnabled)
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        overlayPosition = OverlayPosition(
            rawValue: defaults.string(forKey: Key.overlayPosition) ?? ""
        ) ?? .topCenter
        didShowCleanupWarning = defaults.bool(forKey: Key.didShowCleanupWarning)
    }
}
