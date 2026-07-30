@preconcurrency import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    let database = LocalDatabase.shared
    let preferences = AppPreferences()
    let permissions = PermissionService()
    let modelManager = ModelManager()
    let cleanupModelManager = LocalCleanupModelManager()
    let launchAtLogin = LaunchAtLoginService()
    let historyStore: HistoryStore
    let dictionaryStore: DictionaryStore
    let snippetStore: SnippetStore
    let coordinator: DictationCoordinator

    private let cleanupEngine: LocalCleanupEngine
    private let monitor = GlobalFnMonitor()
    private let overlay = OverlayPanelController()
    private let statusItem = StatusItemController()
    private let soundPlayer = SoundEffectPlayer()
    private(set) var modelStatus: ModelStatus = .missing
    private(set) var cleanupModelStatus: LocalCleanupModelStatus = .missing
    private(set) var setupProgress: Double?
    private(set) var setupMessage: String?
    private(set) var cleanupSetupProgress: Double?
    private(set) var cleanupSetupMessage: String?
    private(set) var microphoneGranted = false
    private(set) var accessibilityGranted = false

    private init() {
        let history = HistoryStore(database: database)
        let dictionary = DictionaryStore(database: database)
        let snippets = SnippetStore(database: database)
        historyStore = history
        dictionaryStore = dictionary
        snippetStore = snippets

        let runtimeURL = Bundle.main.resourceURL?
            .appending(path: "LocalCleanupRuntime", directoryHint: .isDirectory)
            .appending(path: "llama-server")
            ?? URL(fileURLWithPath: "/missing/llama-server")
        let localCleanup = LocalCleanupEngine(
            transport: LlamaServerController(
                executableURL: runtimeURL,
                modelURL: cleanupModelManager.modelURL
            )
        )
        cleanupEngine = localCleanup
        coordinator = DictationCoordinator(
            audio: AudioCaptureService(),
            transcriptionEngine: ParakeetTranscriptionEngine(modelManager: modelManager),
            cleanupEngine: localCleanup,
            pasteService: SystemPasteService(),
            database: database,
            historyStore: history,
            dictionaryStore: dictionary,
            snippetStore: snippets,
            preferences: preferences,
            permissions: permissions,
            mediaPlayback: MediaPlaybackService(),
            soundPlayer: soundPlayer
        )
        coordinator.onStateChange = { [weak overlay, weak preferences] state in
            guard let preferences else { return }
            overlay?.update(for: state, position: preferences.overlayPosition)
        }
        monitor.onPress = { [weak coordinator] in
            coordinator?.beginListening()
        }
        monitor.onRelease = { [weak coordinator] in
            coordinator?.finishListening()
        }
        monitor.onInterrupt = { [weak coordinator] in
            coordinator?.cancel()
        }
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        statusItem.setEnabled(preferences.showMenuBarIcon)
        monitor.start()
        refreshPermissions()
        Task {
            do {
                _ = try await modelManager.prepareFromExistingCache()
            } catch {
                setupMessage = error.localizedDescription
            }
            modelStatus = await modelManager.status()
            do {
                _ = try await cleanupModelManager.prepareFromExistingCache()
            } catch {
                cleanupSetupMessage = error.localizedDescription
            }
            cleanupModelStatus = await cleanupModelManager.status()
            await reloadStores()
        }
    }

    func reloadStores() async {
        await historyStore.reload()
        await dictionaryStore.reload()
        await snippetStore.reload()
    }

    func refreshPermissions() {
        microphoneGranted = permissions.microphoneGranted
        accessibilityGranted = permissions.accessibilityGranted
    }

    func requestMicrophone() {
        Task {
            _ = await permissions.requestMicrophone()
            refreshPermissions()
        }
    }

    func requestAccessibility() {
        permissions.requestAccessibility()
        Task {
            try? await Task.sleep(for: .seconds(1))
            refreshPermissions()
        }
    }

    func setMenuBarIconEnabled(_ enabled: Bool) {
        preferences.showMenuBarIcon = enabled
        statusItem.setEnabled(enabled)
    }

    func playReadySoundPreview() {
        soundPlayer?.playStartCue()
    }

    func downloadModel() {
        guard setupProgress == nil else { return }
        setupProgress = 0
        setupMessage = "Downloading and verifying the official Parakeet model…"
        Task {
            do {
                try await modelManager.download { progress in
                    Task { @MainActor [weak self] in self?.setupProgress = progress }
                }
                modelStatus = await modelManager.status()
                setupMessage = "Parakeet Unified English is ready."
            } catch {
                setupMessage = error.localizedDescription
            }
            setupProgress = nil
        }
    }

    func downloadCleanupModel() {
        guard cleanupSetupProgress == nil else { return }
        cleanupSetupProgress = 0
        cleanupSetupMessage = "Downloading and verifying the 2.1 GB local cleanup model…"
        Task {
            do {
                try await cleanupModelManager.download { progress in
                    Task { @MainActor [weak self] in
                        self?.cleanupSetupProgress = progress
                    }
                }
                cleanupModelStatus = await cleanupModelManager.status()
                cleanupSetupMessage = "Qwen2.5 3B local cleanup is ready."
            } catch {
                cleanupSetupMessage = error.localizedDescription
            }
            cleanupSetupProgress = nil
        }
    }

    func shutdown() async {
        monitor.stop()
        await cleanupEngine.shutdown()
    }
}
