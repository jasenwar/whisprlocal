import Foundation
import XCTest
@testable import WhisprLocal

final class DictationCoordinatorTests: XCTestCase {
    @MainActor
    func testMediaPauseFinishesBeforeAudioCaptureStarts() async throws {
        let events = LockedEventRecorder()
        let audio = FakeAudioCapture(events: events)
        let media = OrderedMediaPlayback(
            events: events,
            delay: .milliseconds(40)
        )
        let fixture = try makeFixture(audio: audio, media: media)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.coordinator.beginListening()
        try await Task.sleep(for: .milliseconds(90))

        XCTAssertEqual(
            events.values,
            ["media-begin", "media-finished", "capture-start"]
        )
        XCTAssertTrue(audio.isRecording)
        fixture.coordinator.cancel()
    }

    @MainActor
    func testReleaseDuringPreparationNeverStartsDelayedCapture() async throws {
        let events = LockedEventRecorder()
        let audio = FakeAudioCapture(events: events)
        let media = OrderedMediaPlayback(
            events: events,
            delay: .milliseconds(100)
        )
        let fixture = try makeFixture(audio: audio, media: media)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.coordinator.beginListening()
        try await Task.sleep(for: .milliseconds(10))
        fixture.coordinator.finishListening()
        try await Task.sleep(for: .milliseconds(140))

        XCTAssertFalse(audio.isRecording)
        XCTAssertFalse(events.values.contains("capture-start"))
        XCTAssertEqual(fixture.coordinator.state, .cancelled)
    }

    @MainActor
    func testCancelDuringPreparationNeverStartsDelayedCapture() async throws {
        let events = LockedEventRecorder()
        let audio = FakeAudioCapture(events: events)
        let media = OrderedMediaPlayback(
            events: events,
            delay: .milliseconds(100)
        )
        let fixture = try makeFixture(audio: audio, media: media)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        fixture.coordinator.beginListening()
        try await Task.sleep(for: .milliseconds(10))
        fixture.coordinator.cancel()
        try await Task.sleep(for: .milliseconds(140))

        XCTAssertFalse(audio.isRecording)
        XCTAssertFalse(events.values.contains("capture-start"))
        XCTAssertEqual(fixture.coordinator.state, .cancelled)
    }

    @MainActor
    private func makeFixture(
        audio: any AudioCapturing,
        media: any MediaPlaybackControlling
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
        preferences.cleanupEnabled = false

        let coordinator = DictationCoordinator(
            audio: audio,
            transcriptionEngine: NoopTranscriptionEngine(),
            cleanupEngine: NoopCleanupEngine(),
            pasteService: SystemPasteService(),
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

@MainActor
private final class FakeAudioCapture: AudioCapturing {
    private let events: LockedEventRecorder
    private(set) var isRecording = false
    private(set) var selectedInputDeviceName: String? = "Test microphone"

    init(events: LockedEventRecorder) {
        self.events = events
    }

    func start() {
        events.append("capture-start")
        isRecording = true
    }

    func stop() -> [Float] {
        isRecording = false
        return Array(repeating: 0.1, count: 16_000)
    }

    func cancel() {
        isRecording = false
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
