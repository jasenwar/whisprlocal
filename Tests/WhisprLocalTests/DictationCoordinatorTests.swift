import Foundation
import XCTest
@testable import WhisprLocal

final class DictationCoordinatorTests: XCTestCase {
    @MainActor
    func testMediaPauseFinishesBeforeAudioCaptureStarts() async throws {
        let events = LockedEventRecorder()
        let audio = FakeAudioCapture(events: events)
        let media = OrderedMediaPlayback(events: events)
        let database = try LocalDatabase(
            path: FileManager.default.temporaryDirectory
                .appending(path: "WhisprLocalCoordinator-\(UUID().uuidString).sqlite")
                .path
        )
        let defaultsName = "WhisprLocalCoordinatorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
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

        coordinator.beginListening()
        try await Task.sleep(for: .milliseconds(90))

        XCTAssertEqual(
            events.values,
            ["media-begin", "media-finished", "capture-start"]
        )
        XCTAssertTrue(audio.isRecording)
        coordinator.cancel()
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

    func start(inputMode: AudioInputMode) {
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

    init(events: LockedEventRecorder) {
        self.events = events
    }

    func beginDictation(_ id: UUID) async {
        events.append("media-begin")
        try? await Task.sleep(for: .milliseconds(40))
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
