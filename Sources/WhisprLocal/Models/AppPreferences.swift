import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    private enum Key {
        static let autoPaste = "autoPaste"
        static let sounds = "sounds"
        static let cleanupEnabled = "cleanupEnabled"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let didShowCleanupWarning = "didShowCleanupWarning"
    }

    private let defaults: UserDefaults

    var autoPaste: Bool {
        didSet { defaults.set(autoPaste, forKey: Key.autoPaste) }
    }

    var sounds: Bool {
        didSet { defaults.set(sounds, forKey: Key.sounds) }
    }

    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Key.cleanupEnabled) }
    }

    var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }

    var didShowCleanupWarning: Bool {
        didSet { defaults.set(didShowCleanupWarning, forKey: Key.didShowCleanupWarning) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.autoPaste: true,
            Key.sounds: true,
            Key.cleanupEnabled: true,
            Key.showMenuBarIcon: false,
            Key.didShowCleanupWarning: false
        ])
        autoPaste = defaults.bool(forKey: Key.autoPaste)
        sounds = defaults.bool(forKey: Key.sounds)
        cleanupEnabled = defaults.bool(forKey: Key.cleanupEnabled)
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        didShowCleanupWarning = defaults.bool(forKey: Key.didShowCleanupWarning)
    }
}
