@preconcurrency import AppKit
import Foundation
import Observation

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
    private var targetApplication: NSRunningApplication?
    private var processingTask: Task<Void, Never>?
    private var mediaPauseTask: Task<Void, Never>?
    private var recordingToken = UUID()

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
        mediaPlayback: any MediaPlaybackControlling
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
    }

    func beginListening() {
        guard state == .idle else { return }
        targetApplication = NSWorkspace.shared.frontmostApplication
        recordingToken = UUID()
        let token = recordingToken
        transition(to: .listening)
        beginMediaPause(for: token)
        play(named: "Tink")

        processingTask = Task { [weak self] in
            guard let self else { return }
            async let transcriberWarmup: Void = transcriptionEngine.prewarm()
            async let cleanupWarmup: Void = cleanupEngine.prewarm()
            let permitted = await permissions.requestMicrophone()
            guard !Task.isCancelled, token == recordingToken else { return }
            guard permitted else {
                fail(WhisprLocalError.microphoneDenied)
                return
            }
            do {
                try audio.start()
            } catch {
                fail(error)
            }
            _ = await (transcriberWarmup, cleanupWarmup)
        }
    }

    func finishListening() {
        guard state == .listening else { return }
        processingTask?.cancel()
        let samples = audio.stop()
        endMediaPause(for: recordingToken)
        transition(to: .transcribing)
        play(named: "Pop")
        processingTask = Task { [weak self] in
            await self?.process(samples: samples)
        }
    }

    func cancel() {
        guard state.isBusy else { return }
        processingTask?.cancel()
        audio.cancel()
        endMediaPause(for: recordingToken)
        transition(to: .cancelled)
        play(named: "Funk")
        settleToIdle()
    }

    private func process(samples: [Float]) async {
        let started = ContinuousClock.now
        do {
            let hotwords = dictionaryStore.terms + snippetStore.snippets.map(\.trigger)
            let transcript = try await transcriptionEngine.transcribe(
                samples: samples,
                sampleRate: 16_000,
                hotwords: hotwords
            )
            try Task.checkCancellation()
            lastRawText = transcript.text
            transition(to: .correcting)

            var corrected = transcript.text
            var cleanupIdentifier = "raw fallback"
            if preferences.cleanupEnabled {
                do {
                    corrected = try await cleanupEngine.correct(
                        text: transcript.text,
                        dictionary: dictionaryStore.terms
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
            let latency = (ContinuousClock.now - started).timeInterval
            var status = "completed"

            if preferences.autoPaste {
                transition(to: .pasting)
                if let targetApplication, !targetApplication.isTerminated {
                    targetApplication.activate()
                    try? await Task.sleep(for: .milliseconds(80))
                }
                try await pasteService.paste(corrected)
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
            play(named: "Glass")
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
        audio.cancel()
        endMediaPause(for: recordingToken)
        transition(to: .failed(error.localizedDescription))
        play(named: "Basso")
        settleToIdle()
    }

    private func transition(to next: DictationState) {
        do {
            try machine.transition(to: next)
            state = next
            onStateChange?(next)
        } catch {
            state = .failed(error.localizedDescription)
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

    private func play(named name: String) {
        guard preferences.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
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
