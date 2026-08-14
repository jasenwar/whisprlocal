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
    let groqCredentialStore = GroqCredentialStore()
    let groqCredentialState = GroqCredentialState()
    let groqAvailability = GroqAvailabilityStore()
    let historyStore: HistoryStore
    let dictionaryStore: DictionaryStore
    let snippetStore: SnippetStore
    let coordinator: DictationCoordinator
    let groqClient: GroqAPIClient
    let contextCaptureService: AppContextCaptureService
    let contextService: GroqContextService

    private let cleanupEngine: any CleanupEngine
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
    private(set) var screenCaptureGranted = false
    private(set) var hasGroqAPIKey = false
    private(set) var groqStatus: GroqAvailabilitySnapshot = .missingCredential
    private(set) var groqConnectionMessage: String?
    private(set) var isTestingGroqConnection = false
    private(set) var cleanupTestResult: CleanupTestResult?
    private(set) var cleanupTestError: String?
    private(set) var isRunningCleanupTest = false
    private(set) var contextTestResult: DictationContext?
    private(set) var contextTestError: String?
    private(set) var isRunningContextTest = false

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
        let credentialState = groqCredentialState
        let client = GroqAPIClient(
            apiKeyProvider: { [credentialState] in
                credentialState.apiKey
            }
        )
        groqClient = client
        let captureService = AppContextCaptureService()
        contextCaptureService = captureService
        let groqContext = GroqContextService(
            client: client,
            captureService: captureService,
            availability: groqAvailability
        )
        contextService = groqContext
        let appPreferences = preferences
        let runtimeConfiguration:
            @MainActor @Sendable () -> GroqRuntimeConfiguration = {
                GroqRuntimeConfiguration(
                    processingMode: appPreferences.processingMode,
                    hasCredential: credentialState.apiKey != nil,
                    transcriptionModel: appPreferences.groqTranscriptionModel,
                    cleanupModel: appPreferences.groqCleanupModel,
                    customCleanupPrompt: appPreferences.customGroqCleanupPrompt
                )
            }
        let localTranscription = ParakeetTranscriptionEngine(
            modelManager: modelManager
        )
        let hybridTranscription = HybridTranscriptionEngine(
            localEngine: localTranscription,
            client: client,
            availability: groqAvailability,
            configuration: runtimeConfiguration
        )
        let hybridCleanup = HybridCleanupEngine(
            localEngine: localCleanup,
            client: client,
            availability: groqAvailability,
            configuration: runtimeConfiguration
        )
        cleanupEngine = hybridCleanup
        coordinator = DictationCoordinator(
            audio: AudioCaptureService(),
            transcriptionEngine: hybridTranscription,
            cleanupEngine: hybridCleanup,
            pasteService: SystemPasteService(),
            database: database,
            historyStore: history,
            dictionaryStore: dictionary,
            snippetStore: snippets,
            preferences: preferences,
            permissions: permissions,
            mediaPlayback: MediaPlaybackService(),
            soundPlayer: soundPlayer,
            contextService: groqContext
        )
        coordinator.onStateChange = { [weak overlay, weak preferences] state in
            guard let preferences else { return }
            overlay?.update(
                for: state,
                position: preferences.overlayPosition,
                style: preferences.indicatorStyle
            )
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
        launchAtLogin.migrateLegacyRegistrationIfNeeded()
        launchAtLogin.repairRegistrationIfNeeded()
        statusItem.setEnabled(preferences.showMenuBarIcon)
        monitor.start()
        refreshPermissions()
        refreshGroqStatus()
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
        screenCaptureGranted = contextCaptureService.hasScreenCapturePermission
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

    func requestScreenCapture() {
        contextCaptureService.requestScreenCapturePermission()
        Task {
            try? await Task.sleep(for: .seconds(1))
            refreshPermissions()
        }
    }

    func refreshGroqStatus() {
        let credentialStore = groqCredentialStore
        let credentialState = groqCredentialState
        let expectedRevision = credentialState.currentRevision
        Task {
            let storedKey = await Task.detached(priority: .userInitiated) {
                credentialStore.apiKey()
            }.value
            _ = credentialState.setIfUnchanged(
                storedKey,
                since: expectedRevision
            )
            let hasCredential = credentialState.apiKey != nil
            hasGroqAPIKey = hasCredential
            groqStatus = await groqAvailability.snapshot(
                hasCredential: hasCredential
            )
        }
    }

    func saveGroqAPIKey(_ apiKey: String) {
        let credentialStore = groqCredentialStore
        let credentialState = groqCredentialState
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try credentialStore.save(apiKey: trimmed)
                }.value
                credentialState.set(trimmed)
                hasGroqAPIKey = !trimmed.isEmpty
                groqConnectionMessage = "API key saved securely in Keychain."
                await groqAvailability.credentialChanged()
                refreshGroqStatus()
            } catch {
                groqConnectionMessage = error.localizedDescription
            }
        }
    }

    func removeGroqAPIKey() {
        let credentialStore = groqCredentialStore
        let credentialState = groqCredentialState
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try credentialStore.remove()
                }.value
                credentialState.set(nil)
                hasGroqAPIKey = false
                groqConnectionMessage = "Groq disconnected. Fully local processing remains available."
                await groqAvailability.credentialChanged()
                refreshGroqStatus()
            } catch {
                groqConnectionMessage = error.localizedDescription
            }
        }
    }

    func testGroqConnection() {
        guard !isTestingGroqConnection else { return }
        isTestingGroqConnection = true
        groqConnectionMessage = nil
        Task {
            do {
                try await groqClient.validateCredential()
                await groqAvailability.recordConnectionSuccess()
                groqConnectionMessage = "Connected to Groq successfully."
            } catch let error as GroqAPIError {
                await groqAvailability.recordConnectionFailure(error)
                groqConnectionMessage = error.localizedDescription
            } catch {
                groqConnectionMessage = error.localizedDescription
            }
            isTestingGroqConnection = false
            refreshGroqStatus()
        }
    }

    func runGroqCleanupTest(text: String) {
        guard !isRunningCleanupTest else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cleanupTestError = "Enter a sample dictation first."
            return
        }
        guard groqClient.hasCredential else {
            cleanupTestError = "Add a Groq API key in Intelligence first."
            return
        }
        isRunningCleanupTest = true
        cleanupTestError = nil
        cleanupTestResult = nil
        let dictionary = dictionaryStore.terms
        let model = preferences.groqCleanupModel
        let scope = GroqRequestScope.cleanup(model)
        let customPrompt = preferences.customGroqCleanupPrompt
        Task {
            let started = ContinuousClock.now
            let protected = TranscriptProtector.protect(
                trimmed,
                dictionary: dictionary
            )
            let systemPrompt = customPrompt.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? GroqCleanupPrompt.system : customPrompt
            let userPrompt = GroqCleanupPrompt.userMessage(
                protectedText: protected.text,
                dictionary: dictionary,
                context: nil
            )
            do {
                let raw = try await groqClient.complete(
                    systemPrompt: systemPrompt,
                    userText: userPrompt,
                    model: model.rawValue,
                    maximumTokens: model.maximumCompletionTokens
                )
                try TranscriptPreservationValidator.validate(
                    original: protected.text,
                    cleaned: raw
                )
                let restored = try protected.restore(raw)
                cleanupTestResult = CleanupTestResult(
                    rawText: trimmed,
                    cleanedText: DeterministicTranscriptCleanup.finalize(restored),
                    engine: model.title,
                    prompt: "[System]\n\(systemPrompt)\n\n[User]\n\(userPrompt)",
                    latency: (ContinuousClock.now - started).timeInterval
                )
                await groqAvailability.recordSuccess(scope)
            } catch let error as GroqAPIError {
                await groqAvailability.recordFailure(error, scope: scope)
                cleanupTestError = error.localizedDescription
            } catch {
                cleanupTestError = error.localizedDescription
            }
            isRunningCleanupTest = false
            refreshGroqStatus()
        }
    }

    func runContextTest() async {
        guard !isRunningContextTest else { return }
        guard groqClient.hasCredential else {
            contextTestError = "Add a Groq API key in Intelligence first."
            return
        }
        isRunningContextTest = true
        contextTestError = nil
        contextTestResult = nil
        let result = await contextService.prepare(
            level: preferences.contextAwarenessLevel == .off
                ? .focusedWindow
                : preferences.contextAwarenessLevel,
            excludedBundleIdentifiers:
                preferences.excludedContextBundleIdentifiers,
            customPrompt: preferences.customGroqContextPrompt
        )
        if let result {
            contextTestResult = result
        } else {
            let availability = await groqAvailability.snapshot(
                hasCredential: groqClient.hasCredential
            )
            contextTestError = availability.state == .temporarilyUnavailable
                ? availability.message
                : "No focused-window context was available. Check Screen Recording permission and app exclusions."
        }
        isRunningContextTest = false
        refreshGroqStatus()
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
