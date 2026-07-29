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
}

private actor FakeMediaRemote: MediaRemoteControlling {
    private var isCurrentlyPlaying: Bool
    private var toggleCount = 0

    init(isPlaying: Bool) {
        isCurrentlyPlaying = isPlaying
    }

    func isPlaying() -> Bool {
        isCurrentlyPlaying
    }

    func togglePlayPause() -> Bool {
        toggleCount += 1
        isCurrentlyPlaying.toggle()
        return true
    }

    func recordedToggleCount() -> Int {
        toggleCount
    }

    func simulatePlayback() {
        isCurrentlyPlaying = true
    }
}
