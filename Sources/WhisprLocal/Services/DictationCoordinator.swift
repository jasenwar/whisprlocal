@preconcurrency import AppKit
import Foundation
import Observation
import OSLog

private let dictationLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "Dictation"
)

@MainActor
@Observable
final class DictationCoordinator {
    private(set) var state: DictationState = .idle
    private(set) var lastRawText = ""
    private(set) var lastCorrectedText = ""
    var warningMessage: String?
    var onStateChange: ((DictationState) -> Void)?

    private var machine = DictationStateMachine()
    private let audio: AudioCaptureService
    private let transcriptionEngine: any TranscriptionEngine
    private let cleanupEngine: any CleanupEngine
    private let pasteService: any PasteService
    private let database: LocalDatabase
    private let historyStore: HistoryStore
    private let dictionaryStore: DictionaryStore
    private let snippetStore: SnippetStore
    private let preferences: AppPreferences
    private let permissions: PermissionService
    private let mediaPlayback: any MediaPlaybackControlling
    private let soundPlayer: SoundEffectPlayer?
    private var targetApplication: NSRunningApplication?
    private var processingTask: Task<Void, Never>?
    private var mediaPauseTask: Task<Void, Never>?
    private var readyCueTask: Task<Void, Never>?
    private var recordingToken = UUID()
    private var listeningRequestedAt: ContinuousClock.Instant?

    init(
        audio: AudioCaptureService,
        transcriptionEngine: any TranscriptionEngine,
        cleanupEngine: any CleanupEngine,
        pasteService: any PasteService,
        database: LocalDatabase,
        historyStore: HistoryStore,
        dictionaryStore: DictionaryStore,
        snippetStore: SnippetStore,
        preferences: AppPreferences,
        permissions: PermissionService,
        mediaPlayback: any MediaPlaybackControlling,
        soundPlayer: SoundEffectPlayer?
    ) {
        self.audio = audio
        self.transcriptionEngine = transcriptionEngine
        self.cleanupEngine = cleanupEngine
        self.pasteService = pasteService
        self.database = database
        self.historyStore = historyStore
        self.dictionaryStore = dictionaryStore
        self.snippetStore = snippetStore
        self.preferences = preferences
        self.permissions = permissions
        self.mediaPlayback = mediaPlayback
        self.soundPlayer = soundPlayer
    }

    func beginListening() {
        guard state == .idle else { return }
        targetApplication = NSWorkspace.shared.frontmostApplication
        recordingToken = UUID()
        let token = recordingToken
        listeningRequestedAt = .now
        dictationLogger.info("Fn press received; preparing capture")
        transition(to: .listening)
        beginMediaPause(for: token)

        if permissions.microphoneGranted {
            guard startCapture(for: token) else { return }
            processingTask = Task { [weak self] in
                await self?.prewarmTranscriber()
            }
            return
        }

        processingTask = Task { [weak self] in
            guard let self else { return }
            let permitted = await permissions.requestMicrophone()
            guard !Task.isCancelled, token == recordingToken else { return }
            guard permitted else {
                dictationLogger.error("Microphone permission was denied")
                fail(WhisprLocalError.microphoneDenied)
                return
            }
            guard startCapture(for: token) else { return }
            await prewarmTranscriber()
        }
    }

    func finishListening() {
        guard state == .listening else { return }
        dictationLogger.info(
            "Fn release received; recorderActive=\(self.audio.isRecording, privacy: .public)"
        )
        processingTask?.cancel()
        readyCueTask?.cancel()
        let samples = audio.stop()
        dictationLogger.info(
            "Sending \(samples.count, privacy: .public) samples to transcription"
        )
        endMediaPause(for: recordingToken)
        transition(to: .transcribing)
        playStopCue()
        processingTask = Task { [weak self] in
            await self?.process(samples: samples)
        }
    }

    func cancel() {
        guard state.isBusy else { return }
        dictationLogger.info("Dictation cancelled")
        processingTask?.cancel()
        readyCueTask?.cancel()
        audio.cancel()
        endMediaPause(for: recordingToken)
        transition(to: .cancelled)
        playStopCue()
        settleToIdle()
    }

    private func process(samples: [Float]) async {
        let started = ContinuousClock.now
        do {
            let hotwords = dictionaryStore.terms + snippetStore.snippets.map(\.trigger)
            let transcriptionStarted = ContinuousClock.now
            let transcript = try await transcriptionEngine.transcribe(
                samples: samples,
                sampleRate: 16_000,
                hotwords: hotwords
            )
            dictationLogger.info(
                "Transcription stage completed in \((ContinuousClock.now - transcriptionStarted).timeInterval, format: .fixed(precision: 3), privacy: .public)s"
            )
            try Task.checkCancellation()
            lastRawText = transcript.text
            transition(to: .correcting)

            var corrected = transcript.text
            var cleanupIdentifier = "raw fallback"
            if preferences.cleanupEnabled {
                do {
                    let cleanupStarted = ContinuousClock.now
                    corrected = try await cleanupEngine.correct(
                        text: transcript.text,
                        dictionary: dictionaryStore.terms
                    )
                    dictationLogger.info(
                        "Cleanup stage completed in \((ContinuousClock.now - cleanupStarted).timeInterval, format: .fixed(precision: 3), privacy: .public)s"
                    )
                    cleanupIdentifier = "Apple Foundation Models"
                } catch {
                    showCleanupFallbackWarning(error)
                }
            } else {
                cleanupIdentifier = "disabled"
            }

            try Task.checkCancellation()
            corrected = SnippetExpander.expand(corrected, snippets: snippetStore.snippets)
            lastCorrectedText = corrected
            let pasteText = PasteTextFormatter.withTrailingSpace(corrected)
            let latency = (ContinuousClock.now - started).timeInterval
            var status = "completed"

            if preferences.autoPaste {
                transition(to: .pasting)
                await activateTargetIfNeeded()
                let pasteStarted = ContinuousClock.now
                try await pasteService.paste(
                    pasteText,
                    restoringClipboard: !preferences.keepLastDictationOnClipboard
                )
                dictationLogger.info(
                    "Paste stage completed in \((ContinuousClock.now - pasteStarted).timeInterval, format: .fixed(precision: 3), privacy: .public)s"
                )
                transition(to: .succeeded)
            } else {
                status = "completed_without_paste"
                transition(to: .succeeded)
            }

            _ = try await database.insertTranscription(
                rawText: transcript.text,
                correctedText: corrected,
                audioDuration: TimeInterval(samples.count) / 16_000,
                processingLatency: latency,
                transcriptionEngine: transcript.engine,
                cleanupEngine: cleanupIdentifier,
                status: status
            )
            await historyStore.reload()
            settleToIdle()
        } catch is CancellationError {
            if state.isBusy {
                transition(to: .cancelled)
                settleToIdle()
            }
        } catch {
            fail(error)
        }
    }

    private func showCleanupFallbackWarning(_ error: Error) {
        guard !preferences.didShowCleanupWarning else { return }
        preferences.didShowCleanupWarning = true
        warningMessage = "Cleanup was unavailable, so WhisprLocal pasted the raw transcript. \(error.localizedDescription)"
    }

    private func fail(_ error: Error) {
        dictationLogger.error(
            "Dictation failed in state=\(self.state.label, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        audio.cancel()
        readyCueTask?.cancel()
        endMediaPause(for: recordingToken)
        transition(to: .failed(error.localizedDescription))
        settleToIdle()
    }

    private func transition(to next: DictationState) {
        do {
            try machine.transition(to: next)
            state = next
            dictationLogger.info(
                "State changed to \(next.label, privacy: .public)"
            )
            onStateChange?(next)
        } catch {
            state = .failed(error.localizedDescription)
            dictationLogger.error(
                "Invalid state transition: \(error.localizedDescription, privacy: .public)"
            )
            onStateChange?(state)
        }
    }

    private func settleToIdle() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            guard let self, !state.isBusy else { return }
            transition(to: .idle)
        }
    }

    private func playStopCue() {
        guard preferences.sounds else { return }
        soundPlayer?.playStopCue()
    }

    private func startCapture(for token: UUID) -> Bool {
        guard token == recordingToken, state == .listening else { return false }
        do {
            try audio.start(inputMode: preferences.audioInputMode)
            if let listeningRequestedAt {
                let startupDelay = (
                    ContinuousClock.now - listeningRequestedAt
                ).timeInterval
                dictationLogger.info(
                    "Audio capture active after \(startupDelay, format: .fixed(precision: 3), privacy: .public)s"
                )
            }
            scheduleReadyCue(for: token)
            return true
        } catch {
            dictationLogger.error(
                "Audio capture start failed: \(error.localizedDescription, privacy: .public)"
            )
            fail(error)
            return false
        }
    }

    private func scheduleReadyCue(for token: UUID) {
        guard preferences.sounds else {
            dictationLogger.info(
                "Ready cue skipped because sounds are disabled"
            )
            return
        }
        readyCueTask?.cancel()

        let routeSettleDelay: Duration =
            preferences.audioInputMode == .fastStart
                ? .milliseconds(120)
                : .milliseconds(220)
        readyCueTask = Task { [weak self] in
            try? await Task.sleep(for: routeSettleDelay)
            guard let self,
                  !Task.isCancelled,
                  token == recordingToken,
                  state == .listening else {
                return
            }
            soundPlayer?.playStartCue()
        }
    }

    private func prewarmTranscriber() async {
        await transcriptionEngine.prewarm()
    }

    private func activateTargetIfNeeded() async {
        guard let targetApplication, !targetApplication.isTerminated else {
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                != targetApplication.processIdentifier else {
            dictationLogger.info(
                "Target application already has focus; pasting immediately"
            )
            return
        }

        let activationStarted = ContinuousClock.now
        targetApplication.activate()
        try? await Task.sleep(for: .milliseconds(40))
        dictationLogger.info(
            "Target application activation completed in \((ContinuousClock.now - activationStarted).timeInterval, format: .fixed(precision: 3), privacy: .public)s"
        )
    }

    private func beginMediaPause(for token: UUID) {
        guard preferences.pauseMediaDuringDictation else { return }
        mediaPauseTask = Task { [mediaPlayback] in
            await mediaPlayback.beginDictation(token)
        }
    }

    private func endMediaPause(for token: UUID) {
        let pauseTask = mediaPauseTask
        mediaPauseTask = nil
        Task { [mediaPlayback] in
            await pauseTask?.value
            await mediaPlayback.endDictation(token)
        }
    }
}
