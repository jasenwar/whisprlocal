import Dispatch
import Foundation
import OSLog
@preconcurrency import AppKit

private let mediaPlaybackLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "MediaPlayback"
)

protocol MediaPlaybackControlling: Sendable {
    func beginDictation(_ id: UUID) async
    func endDictation(_ id: UUID) async
}

enum MediaPlaybackState: String, Sendable {
    case playing
    case paused
    case unavailable
}

protocol MediaRemoteControlling: Sendable {
    func playbackState() async -> MediaPlaybackState
    func togglePlayPause() async -> Bool
}

actor MediaPlaybackService: MediaPlaybackControlling {
    private let remote: any MediaRemoteControlling
    private var activeDictations: Set<UUID> = []
    private var pausedByWhisprLocal = false

    init(remote: any MediaRemoteControlling = MediaRemoteClient()) {
        self.remote = remote
    }

    func beginDictation(_ id: UUID) async {
        activeDictations.insert(id)
        guard !pausedByWhisprLocal else {
            mediaPlaybackLogger.info(
                "Pause skipped because WhisprLocal already owns the paused state"
            )
            return
        }

        let stateStarted = ContinuousClock.now
        let state = await remote.playbackState()
        mediaPlaybackLogger.info(
            "Playback state before capture=\(state.rawValue, privacy: .public) resolved in \((ContinuousClock.now - stateStarted).timeInterval, format: .fixed(precision: 3), privacy: .public)s"
        )
        guard state == .playing else {
            mediaPlaybackLogger.info(
                "Pause command skipped for playback state=\(state.rawValue, privacy: .public)"
            )
            return
        }
        guard activeDictations.contains(id), !pausedByWhisprLocal else { return }

        let posted = await remote.togglePlayPause()
        mediaPlaybackLogger.info(
            "Pause command posted success=\(posted, privacy: .public)"
        )
        if posted {
            pausedByWhisprLocal = true
        }
    }

    func endDictation(_ id: UUID) async {
        activeDictations.remove(id)
        guard activeDictations.isEmpty, pausedByWhisprLocal else { return }

        var state = await remote.playbackState()
        if state == .unavailable {
            try? await Task.sleep(for: .milliseconds(50))
            state = await remote.playbackState()
            mediaPlaybackLogger.info(
                "Playback state retry before resume=\(state.rawValue, privacy: .public)"
            )
        }
        guard state != .playing else {
            mediaPlaybackLogger.info(
                "Resume command skipped for playback state=\(state.rawValue, privacy: .public)"
            )
            pausedByWhisprLocal = false
            return
        }
        if state == .unavailable {
            mediaPlaybackLogger.info(
                "Posting owned resume despite unavailable playback state"
            )
        }
        let posted = await remote.togglePlayPause()
        mediaPlaybackLogger.info(
            "Resume command posted success=\(posted, privacy: .public)"
        )
        pausedByWhisprLocal = false
    }
}

private final class MediaRemoteClient: MediaRemoteControlling, @unchecked Sendable {
    private typealias PlayingCallback = @convention(block) (Bool) -> Void
    private typealias GetPlayingFunction = @convention(c) (
        DispatchQueue,
        @escaping PlayingCallback
    ) -> Void
    private let handle: UnsafeMutableRawPointer?
    private let getPlaying: GetPlayingFunction?

    init() {
        let framework = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW
        )
        handle = framework

        if let framework,
           let symbol = dlsym(
               framework,
               "MRMediaRemoteGetNowPlayingApplicationIsPlaying"
           ) {
            getPlaying = unsafeBitCast(symbol, to: GetPlayingFunction.self)
        } else {
            getPlaying = nil
        }

    }

    func playbackState() async -> MediaPlaybackState {
        guard let getPlaying else { return .unavailable }

        return await withCheckedContinuation { continuation in
            let request = PlayingStateRequest(continuation: continuation)
            getPlaying(.global(qos: .userInitiated)) { isPlaying in
                request.complete(
                    with: isPlaying ? .playing : .paused
                )
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .milliseconds(75)
            ) {
                request.complete(with: .unavailable)
            }
        }
    }

    func togglePlayPause() async -> Bool {
        for keyState in [0xA, 0xB] {
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(
                    rawValue: keyState == 0xA ? 0xA00 : 0xB00
                ),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (16 << 16) | (keyState << 8),
                data2: -1
            )?.cgEvent else {
                return false
            }
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}

private final class PlayingStateRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MediaPlaybackState, Never>?

    init(
        continuation: CheckedContinuation<MediaPlaybackState, Never>
    ) {
        self.continuation = continuation
    }

    func complete(with value: MediaPlaybackState) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
