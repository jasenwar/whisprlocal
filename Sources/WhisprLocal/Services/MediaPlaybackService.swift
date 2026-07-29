import Dispatch
import Foundation
@preconcurrency import AppKit

protocol MediaPlaybackControlling: Sendable {
    func beginDictation(_ id: UUID) async
    func endDictation(_ id: UUID) async
}

protocol MediaRemoteControlling: Sendable {
    func isPlaying() async -> Bool
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
        guard !pausedByWhisprLocal else { return }
        guard await remote.isPlaying() else { return }
        guard activeDictations.contains(id), !pausedByWhisprLocal else { return }

        if await remote.togglePlayPause() {
            pausedByWhisprLocal = true
        }
    }

    func endDictation(_ id: UUID) async {
        activeDictations.remove(id)
        guard activeDictations.isEmpty, pausedByWhisprLocal else { return }
        if !(await remote.isPlaying()) {
            _ = await remote.togglePlayPause()
        }
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

    func isPlaying() async -> Bool {
        guard let getPlaying else { return false }

        return await withCheckedContinuation { continuation in
            let request = PlayingStateRequest(continuation: continuation)
            getPlaying(.global(qos: .userInitiated)) { isPlaying in
                request.complete(with: isPlaying)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .milliseconds(500)
            ) {
                request.complete(with: false)
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
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func complete(with value: Bool) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
