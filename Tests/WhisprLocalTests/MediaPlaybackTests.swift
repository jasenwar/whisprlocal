import Foundation
import XCTest
@testable import WhisprLocal

final class MediaPlaybackTests: XCTestCase {
    func testPlayingMediaPausesAndResumes() async {
        let remote = FakeMediaRemote(isPlaying: true)
        let service = MediaPlaybackService(remote: remote)
        let id = UUID()

        await service.beginDictation(id)
        await service.endDictation(id)

        let toggleCount = await remote.recordedToggleCount()
        XCTAssertEqual(toggleCount, 2)
    }

    func testAlreadyPausedMediaRemainsPaused() async {
        let remote = FakeMediaRemote(isPlaying: false)
        let service = MediaPlaybackService(remote: remote)
        let id = UUID()

        await service.beginDictation(id)
        await service.endDictation(id)

        let toggleCount = await remote.recordedToggleCount()
        XCTAssertEqual(toggleCount, 0)
    }

    func testOverlappingSessionsResumeAfterLastSessionEnds() async {
        let remote = FakeMediaRemote(isPlaying: true)
        let service = MediaPlaybackService(remote: remote)
        let first = UUID()
        let second = UUID()

        await service.beginDictation(first)
        await service.beginDictation(second)
        await service.endDictation(first)
        let togglesBeforeFinalSessionEnds = await remote.recordedToggleCount()
        XCTAssertEqual(togglesBeforeFinalSessionEnds, 1)

        await service.endDictation(second)
        let finalToggleCount = await remote.recordedToggleCount()
        XCTAssertEqual(finalToggleCount, 2)
    }

    func testManualResumeDuringDictationIsNotToggledOffAtEnd() async {
        let remote = FakeMediaRemote(isPlaying: true)
        let service = MediaPlaybackService(remote: remote)
        let id = UUID()

        await service.beginDictation(id)
        await remote.simulatePlayback()
        await service.endDictation(id)

        let toggleCount = await remote.recordedToggleCount()
        XCTAssertEqual(toggleCount, 1)
    }

    func testUnavailablePlaybackStateNeverPostsMediaKey() async {
        let remote = FakeMediaRemote(state: .unavailable)
        let service = MediaPlaybackService(remote: remote)
        let id = UUID()

        await service.beginDictation(id)
        await service.endDictation(id)

        let toggleCount = await remote.recordedToggleCount()
        XCTAssertEqual(toggleCount, 0)
    }

    func testOwnedPauseResumesWhenPlaybackStateBecomesUnavailable() async {
        let remote = FakeMediaRemote(isPlaying: true)
        let service = MediaPlaybackService(remote: remote)
        let id = UUID()

        await service.beginDictation(id)
        await remote.simulateUnavailable()
        await service.endDictation(id)

        let toggleCount = await remote.recordedToggleCount()
        XCTAssertEqual(toggleCount, 2)
    }
}

private actor FakeMediaRemote: MediaRemoteControlling {
    private var state: MediaPlaybackState
    private var toggleCount = 0

    init(isPlaying: Bool) {
        state = isPlaying ? .playing : .paused
    }

    init(state: MediaPlaybackState) {
        self.state = state
    }

    func playbackState() -> MediaPlaybackState {
        state
    }

    func togglePlayPause() -> Bool {
        toggleCount += 1
        switch state {
        case .playing:
            state = .paused
        case .paused:
            state = .playing
        case .unavailable:
            state = .playing
        }
        return true
    }

    func recordedToggleCount() -> Int {
        toggleCount
    }

    func simulatePlayback() {
        state = .playing
    }

    func simulateUnavailable() {
        state = .unavailable
    }
}
