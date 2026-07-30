import Foundation
import Darwin
import XCTest
@testable import WhisprLocal

final class DictationCoordinatorTests: XCTestCase {
    @MainActor
    func testMediaPauseDoesNotBlockAudioCaptureStartup() async throws {
        let events = LockedEventRecorder()
        let audio = FakeAudioCapture(events: events)
        let media = OrderedMediaPlayback(
            events: events,
            delay: .milliseconds(120)
        )
        let fixture = try makeFixture(audio: audio, media: media)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.coordinator.beginListening()
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertTrue(events.values.contains("capture-ready"))
        XCTAssertFalse(events.values.contains("media-finished"))
        let isRecording = await audio.recordingStatus()
        XCTAssertTrue(isRecording)
        try await Task.sleep(for: .milliseconds(120))
        let completedEvents = events.values
        let captureReady = try XCTUnwrap(
            completedEvents.firstIndex(of: "capture-ready")
        )
        let mediaFinished = try XCTUnwrap(
            completedEvents.firstIndex(of: "media-finished")
        )
        XCTAssertLessThan(captureReady, mediaFinished)
        fixture.coordinator.cancel()
    }

    @MainActor
    func testReleaseDuringPreparationNeverStartsDelayedCapture() async throws {
        let events = LockedEventRecorder()
        let audio = FakeAudioCapture(
            events: events,
            startDelay: .milliseconds(120)
        )
        let media = OrderedMediaPlayback(
            events: events,
            delay: .milliseconds(20)
        )
        let fixture = try makeFixture(audio: audio, media: media)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.coordinator.beginListening()
        try await Task.sleep(for: .milliseconds(10))
        fixture.coordinator.finishListening()
        try await Task.sleep(for: .milliseconds(140))

        let isRecording = await audio.recordingStatus()
        XCTAssertFalse(isRecording)
        XCTAssertTrue(events.values.contains("capture-start"))
        XCTAssertFalse(events.values.contains("capture-ready"))
        XCTAssertEqual(fixture.coordinator.state, .cancelled)
    }

    @MainActor
    func testCancelDuringPreparationNeverStartsDelayedCapture() async throws {
        let events = LockedEventRecorder()
        let audio = FakeAudioCapture(
            events: events,
            startDelay: .milliseconds(120)
        )
        let media = OrderedMediaPlayback(
            events: events,
            delay: .milliseconds(20)
        )
        let fixture = try makeFixture(audio: audio, media: media)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.coordinator.beginListening()
        try await Task.sleep(for: .milliseconds(10))
        fixture.coordinator.cancel()
        try await Task.sleep(for: .milliseconds(140))

        let isRecording = await audio.recordingStatus()
        XCTAssertFalse(isRecording)
        XCTAssertTrue(events.values.contains("capture-start"))
        XCTAssertFalse(events.values.contains("capture-ready"))
        XCTAssertEqual(fixture.coordinator.state, .cancelled)
    }

    @MainActor
    func testProcessingStagesContinueWhileMainActorIsBusy() async throws {
        let events = LockedEventRecorder()
        let audio = FakeAudioCapture(events: events)
        let paste = RecordingPasteService(events: events)
        let fixture = try makeFixture(
            audio: audio,
            media: OrderedMediaPlayback(events: events, delay: .zero),
            transcriptionEngine: OrderedTranscriptionEngine(
                events: events,
                delay: .milliseconds(20)
            ),
            cleanupEngine: OrderedCleanupEngine(
                events: events,
                delay: .milliseconds(20)
            ),
            pasteService: paste,
            cleanupEnabled: true
        )
        defer {
            fixture.defaults.removePersistentDomain(
                forName: fixture.suiteName
            )
        }

        fixture.coordinator.beginListening()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(fixture.coordinator.state, .listening)

        fixture.coordinator.finishListening()
        blockCoordinatorMainThread(forMicroseconds: 150_000)

        XCTAssertTrue(events.values.contains("transcription-finished"))
        XCTAssertTrue(events.values.contains("cleanup-finished"))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fixture.coordinator.state, .succeeded)
        XCTAssertTrue(events.values.contains("paste"))
    }

    @MainActor
    private func makeFixture(
        audio: any AudioCapturing,
        media: any MediaPlaybackControlling,
        transcriptionEngine: any TranscriptionEngine =
            NoopTranscriptionEngine(),
        cleanupEngine: any CleanupEngine = NoopCleanupEngine(),
        pasteService: any PasteService = SystemPasteService(),
        cleanupEnabled: Bool = false
    ) throws -> (
        coordinator: DictationCoordinator,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let database = try LocalDatabase(
            path: FileManager.default.temporaryDirectory
                .appending(path: "WhisprLocalCoordinator-\(UUID().uuidString).sqlite")
                .path
        )
        let suiteName = "WhisprLocalCoordinatorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let preferences = AppPreferences(defaults: defaults)
        preferences.pauseMediaDuringDictation = true
        preferences.cleanupEnabled = cleanupEnabled

        let coordinator = DictationCoordinator(
            audio: audio,
            transcriptionEngine: transcriptionEngine,
            cleanupEngine: cleanupEngine,
            pasteService: pasteService,
            database: database,
            historyStore: HistoryStore(database: database),
            dictionaryStore: DictionaryStore(database: database),
            snippetStore: SnippetStore(database: database),
            preferences: preferences,
            permissions: GrantedMicrophonePermission(),
            mediaPlayback: media,
            soundPlayer: nil
        )
        return (coordinator, defaults, suiteName)
    }
}

private func blockCoordinatorMainThread(
    forMicroseconds duration: useconds_t
) {
    usleep(duration)
}

private final class LockedEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock {
            storage.append(value)
        }
    }
}

private actor FakeAudioCapture: AudioCapturing {
    private let events: LockedEventRecorder
    private let startDelay: Duration
    private var isRecording = false

    init(
        events: LockedEventRecorder,
        startDelay: Duration = .zero
    ) {
        self.events = events
        self.startDelay = startDelay
    }

    func start(mode: MicrophoneMode) async throws -> AudioCaptureStartInfo {
        events.append("capture-start")
        if startDelay > .zero {
            try await Task.sleep(for: startDelay)
        }
        try Task.checkCancellation()
        isRecording = true
        events.append("capture-ready")
        return AudioCaptureStartInfo(
            deviceName: "Test microphone",
            sampleRate: 48_000
        )
    }

    func stop() -> [Float] {
        isRecording = false
        return Array(repeating: 0.1, count: 16_000)
    }

    func cancel() {
        isRecording = false
    }

    func recordingStatus() -> Bool {
        isRecording
    }
}

@MainActor
private final class GrantedMicrophonePermission: DictationPermissionChecking {
    var microphoneGranted: Bool { true }

    func requestMicrophone() async -> Bool {
        true
    }
}

private actor OrderedMediaPlayback: MediaPlaybackControlling {
    private let events: LockedEventRecorder
    private let delay: Duration

    init(events: LockedEventRecorder, delay: Duration) {
        self.events = events
        self.delay = delay
    }

    func beginDictation(_ id: UUID) async {
        events.append("media-begin")
        try? await Task.sleep(for: delay)
        events.append("media-finished")
    }

    func endDictation(_ id: UUID) {}
}

private actor NoopTranscriptionEngine: TranscriptionEngine {
    func transcribe(
        samples: [Float],
        sampleRate: Int,
        hotwords: [String]
    ) -> Transcript {
        Transcript(text: "test", engine: "test", duration: 0)
    }

    func prewarm() {}
    func releaseIfIdle() {}
}

private actor NoopCleanupEngine: CleanupEngine {
    func correct(text: String, dictionary: [String]) -> String {
        text
    }
}

private actor OrderedTranscriptionEngine: TranscriptionEngine {
    private let events: LockedEventRecorder
    private let delay: Duration

    init(events: LockedEventRecorder, delay: Duration) {
        self.events = events
        self.delay = delay
    }

    func transcribe(
        samples: [Float],
        sampleRate: Int,
        hotwords: [String]
    ) async throws -> Transcript {
        events.append("transcription-start")
        try await Task.sleep(for: delay)
        events.append("transcription-finished")
        return Transcript(
            text: "raw test text",
            engine: "test",
            duration: delay.timeInterval
        )
    }

    func prewarm() {}
    func releaseIfIdle() {}
}

private actor OrderedCleanupEngine: CleanupEngine {
    private let events: LockedEventRecorder
    private let delay: Duration

    init(events: LockedEventRecorder, delay: Duration) {
        self.events = events
        self.delay = delay
    }

    func correct(
        text: String,
        dictionary: [String]
    ) async throws -> String {
        events.append("cleanup-start")
        try await Task.sleep(for: delay)
        events.append("cleanup-finished")
        return "Cleaned test text."
    }
}

@MainActor
private final class RecordingPasteService: PasteService {
    private let events: LockedEventRecorder

    init(events: LockedEventRecorder) {
        self.events = events
    }

    func paste(
        _ text: String,
        targetProcessIdentifier: pid_t?,
        restoringClipboard: Bool
    ) {
        events.append("paste")
    }
}
