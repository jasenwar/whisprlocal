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

enum IndicatorStyle: String, CaseIterable, Identifiable, Sendable {
    case floatingPill
    case notch

    var id: Self { self }

    var title: String {
        switch self {
        case .floatingPill: "Floating Pill"
        case .notch: "Notch"
        }
    }
}

@MainActor
@Observable
final class AppPreferences {
    private enum Key {
        static let autoPaste = "autoPaste"
        static let keepLastDictationOnClipboard = "keepLastDictationOnClipboard"
        // Use a new key so diagnostic builds that previously defaulted sounds
        // on migrate to the new silent-by-default behavior.
        static let sounds = "dictationSoundsV2"
        static let pauseMediaDuringDictation = "pauseMediaDuringDictation"
        static let microphoneMode = "microphoneMode"
        static let cleanupEnabled = "cleanupEnabled"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let overlayPosition = "overlayPosition"
        static let indicatorStyle = "indicatorStyle"
        static let didShowCleanupWarning = "didShowCleanupWarning"
        static let processingMode = "processingMode"
        static let contextAwarenessLevel = "contextAwarenessLevel"
        static let groqTranscriptionModel = "groqTranscriptionModel"
        static let groqCleanupModel = "groqCleanupModel"
        static let excludedContextBundleIdentifiers =
            "excludedContextBundleIdentifiers"
        static let customGroqCleanupPrompt = "customGroqCleanupPrompt"
        static let customGroqContextPrompt = "customGroqContextPrompt"
        static let learnFromCorrections = "learnFromCorrections"
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

    var microphoneMode: MicrophoneMode {
        didSet {
            defaults.set(
                microphoneMode.rawValue,
                forKey: Key.microphoneMode
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

    var indicatorStyle: IndicatorStyle {
        didSet { defaults.set(indicatorStyle.rawValue, forKey: Key.indicatorStyle) }
    }

    var didShowCleanupWarning: Bool {
        didSet { defaults.set(didShowCleanupWarning, forKey: Key.didShowCleanupWarning) }
    }

    var processingMode: ProcessingMode {
        didSet { defaults.set(processingMode.rawValue, forKey: Key.processingMode) }
    }

    var contextAwarenessLevel: ContextAwarenessLevel {
        didSet {
            defaults.set(
                contextAwarenessLevel.rawValue,
                forKey: Key.contextAwarenessLevel
            )
        }
    }

    var groqTranscriptionModel: GroqTranscriptionModel {
        didSet {
            defaults.set(
                groqTranscriptionModel.rawValue,
                forKey: Key.groqTranscriptionModel
            )
        }
    }

    var groqCleanupModel: GroqCleanupModel {
        didSet {
            defaults.set(
                groqCleanupModel.rawValue,
                forKey: Key.groqCleanupModel
            )
        }
    }

    var excludedContextBundleIdentifiers: [String] {
        didSet {
            defaults.set(
                excludedContextBundleIdentifiers,
                forKey: Key.excludedContextBundleIdentifiers
            )
        }
    }

    var customGroqCleanupPrompt: String {
        didSet {
            defaults.set(
                customGroqCleanupPrompt,
                forKey: Key.customGroqCleanupPrompt
            )
        }
    }

    var customGroqContextPrompt: String {
        didSet {
            defaults.set(
                customGroqContextPrompt,
                forKey: Key.customGroqContextPrompt
            )
        }
    }

    /// Allows the brief, read-only post-paste correction observer to learn safe
    /// vocabulary mappings. It is intentionally independent of cleanup settings.
    var learnFromCorrections: Bool {
        didSet {
            defaults.set(learnFromCorrections, forKey: Key.learnFromCorrections)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.autoPaste: true,
            Key.keepLastDictationOnClipboard: true,
            Key.sounds: false,
            Key.pauseMediaDuringDictation: true,
            Key.microphoneMode: MicrophoneMode.systemDefault.rawValue,
            Key.cleanupEnabled: true,
            Key.showMenuBarIcon: false,
            Key.overlayPosition: OverlayPosition.topCenter.rawValue,
            Key.indicatorStyle: IndicatorStyle.floatingPill.rawValue,
            Key.didShowCleanupWarning: false,
            Key.processingMode: ProcessingMode.groqPreferred.rawValue,
            Key.contextAwarenessLevel:
                ContextAwarenessLevel.focusedWindow.rawValue,
            Key.groqTranscriptionModel:
                GroqTranscriptionModel.whisperLargeV3.rawValue,
            Key.groqCleanupModel: GroqCleanupModel.gptOSS20B.rawValue,
            Key.excludedContextBundleIdentifiers: [
                "com.1password.1password",
                "com.agilebits.onepassword7",
                "com.apple.Passwords",
                "com.bitwarden.desktop",
            ],
            Key.customGroqCleanupPrompt: "",
            Key.customGroqContextPrompt: "",
            Key.learnFromCorrections: true,
        ])
        autoPaste = defaults.bool(forKey: Key.autoPaste)
        keepLastDictationOnClipboard = defaults.bool(
            forKey: Key.keepLastDictationOnClipboard
        )
        sounds = defaults.bool(forKey: Key.sounds)
        pauseMediaDuringDictation = defaults.bool(
            forKey: Key.pauseMediaDuringDictation
        )
        microphoneMode = MicrophoneMode(
            rawValue: defaults.string(forKey: Key.microphoneMode) ?? ""
        ) ?? .systemDefault
        cleanupEnabled = defaults.bool(forKey: Key.cleanupEnabled)
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        overlayPosition = OverlayPosition(
            rawValue: defaults.string(forKey: Key.overlayPosition) ?? ""
        ) ?? .topCenter
        indicatorStyle = IndicatorStyle(
            rawValue: defaults.string(forKey: Key.indicatorStyle) ?? ""
        ) ?? .floatingPill
        didShowCleanupWarning = defaults.bool(forKey: Key.didShowCleanupWarning)
        processingMode = ProcessingMode(
            rawValue: defaults.string(forKey: Key.processingMode) ?? ""
        ) ?? .groqPreferred
        contextAwarenessLevel = ContextAwarenessLevel(
            rawValue: defaults.string(forKey: Key.contextAwarenessLevel) ?? ""
        ) ?? .focusedWindow
        groqTranscriptionModel = GroqTranscriptionModel(
            rawValue: defaults.string(forKey: Key.groqTranscriptionModel) ?? ""
        ) ?? .whisperLargeV3
        groqCleanupModel = GroqCleanupModel(
            rawValue: defaults.string(forKey: Key.groqCleanupModel) ?? ""
        ) ?? .gptOSS20B
        excludedContextBundleIdentifiers = defaults.stringArray(
            forKey: Key.excludedContextBundleIdentifiers
        ) ?? []
        customGroqCleanupPrompt = defaults.string(
            forKey: Key.customGroqCleanupPrompt
        ) ?? ""
        customGroqContextPrompt = defaults.string(
            forKey: Key.customGroqContextPrompt
        ) ?? ""
        learnFromCorrections = defaults.bool(forKey: Key.learnFromCorrections)
    }
}
