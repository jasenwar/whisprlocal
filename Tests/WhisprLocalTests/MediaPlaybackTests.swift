import Foundation
import XCTest
@testable import WhisprLocal

final class MediaPlaybackTests: XCTestCase {
    func testPlayingMediaReceivesExplicitPauseAndPlay() async {
        let remote = FakeMediaRemote(state: .playing)
        let service = MediaPlaybackService(remote: remote)
        let id = UUID()

        await service.beginDictation(id)
        await service.endDictation(id)

        let commands = await remote.recordedCommands()
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testAlreadyPausedMediaRemainsPaused() async {
        let remote = FakeMediaRemote(state: .paused)
        let service = MediaPlaybackService(remote: remote)
        let id = UUID()

        await service.beginDictation(id)
        await service.endDictation(id)

        let commands = await remote.recordedCommands()
        XCTAssertEqual(commands, [])
    }

    func testOverlappingSessionsResumeAfterLastSessionEnds() async {
        let remote = FakeMediaRemote(state: .playing)
        let service = MediaPlaybackService(remote: remote)
        let first = UUID()
        let second = UUID()

        await service.beginDictation(first)
        await service.beginDictation(second)
        await service.endDictation(first)
        let commandsBeforeFinalSessionEnds =
            await remote.recordedCommands()
        XCTAssertEqual(commandsBeforeFinalSessionEnds, [.pause])

        await service.endDictation(second)
        let finalCommands = await remote.recordedCommands()
        XCTAssertEqual(finalCommands, [.pause, .play])
    }

    func testConcurrentSessionStartsSharePauseOwnership() async {
        let remote = FakeMediaRemote(
            state: .playing,
            pauseDelay: .milliseconds(50)
        )
        let service = MediaPlaybackService(remote: remote)
        let first = UUID()
        let second = UUID()

        async let firstStart: Void = service.beginDictation(first)
        async let secondStart: Void = service.beginDictation(second)
        _ = await (firstStart, secondStart)

        await service.endDictation(first)
        await service.endDictation(second)

        let commands = await remote.recordedCommands()
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testManualResumeDuringDictationIsNeverToggledOffAtEnd() async {
        let remote = FakeMediaRemote(state: .playing)
        let service = MediaPlaybackService(remote: remote)
        let id = UUID()

        await service.beginDictation(id)
        await remote.simulatePlayback()
        await service.endDictation(id)

        let commands = await remote.recordedCommands()
        let state = await remote.currentState()
        XCTAssertEqual(commands, [.pause, .play])
        XCTAssertEqual(state, .playing)
    }

    func testUnavailablePlaybackStatePostsNoCommand() async {
        let remote = FakeMediaRemote(state: .unavailable)
        let service = MediaPlaybackService(remote: remote)
        let id = UUID()

        await service.beginDictation(id)
        await service.endDictation(id)

        let commands = await remote.recordedCommands()
        XCTAssertEqual(commands, [])
    }

    func testOwnedPauseUsesExplicitPlayWhenStateBecomesUnavailable() async {
        let remote = FakeMediaRemote(state: .playing)
        let service = MediaPlaybackService(remote: remote)
        let id = UUID()

        await service.beginDictation(id)
        await remote.simulateUnavailable()
        await service.endDictation(id)

        let commands = await remote.recordedCommands()
        XCTAssertEqual(commands, [.pause, .play])
    }

    func testLatePauseAfterSessionEndsRestoresPlayback() async {
        let remote = FakeMediaRemote(
            state: .playing,
            pauseDelay: .milliseconds(80)
        )
        let service = MediaPlaybackService(remote: remote)
        let id = UUID()

        let beginTask = Task {
            await service.beginDictation(id)
        }
        try? await Task.sleep(for: .milliseconds(10))
        await service.endDictation(id)
        await beginTask.value

        let commands = await remote.recordedCommands()
        let state = await remote.currentState()
        XCTAssertEqual(commands, [.pause, .play])
        XCTAssertEqual(state, .playing)
    }

    func testAdapterStateOutputParsing() {
        XCTAssertEqual(
            MediaRemoteAdapterClient.playbackState(from: "PLAYING"),
            .playing
        )
        XCTAssertEqual(
            MediaRemoteAdapterClient.playbackState(from: "PAUSED"),
            .paused
        )
        XCTAssertEqual(
            MediaRemoteAdapterClient.playbackState(from: "UNAVAILABLE"),
            .unavailable
        )
        XCTAssertEqual(
            MediaRemoteAdapterClient.playbackState(from: ""),
            .unavailable
        )
    }

    func testBundledAdapterReportsPlaybackState() async {
        let client = MediaRemoteAdapterClient()
        let state = await client.playbackStateForDiagnostics()

        XCTAssertNotEqual(state, .unavailable)
    }

    func testAdapterProcessTimeoutReturnsPromptly() async {
        let started = ContinuousClock.now
        let result = await MediaRemoteProcessInvocation(
            executableURL: URL(filePath: "/bin/sleep"),
            arguments: ["2"]
        ).execute(timeout: .milliseconds(30))

        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.terminationStatus)
        XCTAssertLessThan(
            (ContinuousClock.now - started).timeInterval,
            0.5
        )
    }
}

private enum RecordedMediaCommand: Equatable {
    case pause
    case play
}

private actor FakeMediaRemote: MediaRemoteControlling {
    private var state: MediaPlaybackState
    private var commands: [RecordedMediaCommand] = []
    private let pauseDelay: Duration

    init(
        state: MediaPlaybackState,
        pauseDelay: Duration = .zero
    ) {
        self.state = state
        self.pauseDelay = pauseDelay
    }

    func pauseIfPlaying() async -> Bool {
        if pauseDelay > .zero {
            try? await Task.sleep(for: pauseDelay)
        }
        guard state == .playing else {
            return false
        }
        commands.append(.pause)
        state = .paused
        return true
    }

    func play() -> Bool {
        commands.append(.play)
        state = .playing
        return true
    }

    func recordedCommands() -> [RecordedMediaCommand] {
        commands
    }

    func currentState() -> MediaPlaybackState {
        state
    }

    func simulatePlayback() {
        state = .playing
    }

    func simulateUnavailable() {
        state = .unavailable
    }
}
