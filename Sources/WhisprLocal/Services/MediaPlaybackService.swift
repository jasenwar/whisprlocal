import Darwin
import Dispatch
import Foundation
import OSLog

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
    func pauseIfPlaying() async -> Bool
    func play() async -> Bool
}

actor MediaPlaybackService: MediaPlaybackControlling {
    private let remote: any MediaRemoteControlling
    private var activeDictations: Set<UUID> = []
    private var pausedByWhisprLocal = false

    init(
        remote: any MediaRemoteControlling =
            MediaRemoteAdapterClient()
    ) {
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

        let started = ContinuousClock.now
        let posted = await remote.pauseIfPlaying()
        mediaPlaybackLogger.info(
            "State-aware pause completed posted=\(posted, privacy: .public) in \((ContinuousClock.now - started).timeInterval, format: .fixed(precision: 3), privacy: .public)s"
        )

        if posted {
            if activeDictations.isEmpty {
                // Dictation ended while the adapter was pausing. Restore
                // playback immediately instead of losing pause ownership.
                _ = await remote.play()
            } else {
                pausedByWhisprLocal = true
            }
        }
    }

    func endDictation(_ id: UUID) async {
        activeDictations.remove(id)
        guard activeDictations.isEmpty, pausedByWhisprLocal else {
            return
        }

        let started = ContinuousClock.now
        let posted = await remote.play()
        mediaPlaybackLogger.info(
            "Owned explicit play completed posted=\(posted, privacy: .public) in \((ContinuousClock.now - started).timeInterval, format: .fixed(precision: 3), privacy: .public)s"
        )
        pausedByWhisprLocal = false
    }
}

struct MediaRemoteAdapterClient: MediaRemoteControlling {
    private let runner: any MediaRemoteCommandRunning
    private let commandTimeout: Duration

    init(
        runner: any MediaRemoteCommandRunning =
            BundledMediaRemoteCommandRunner(),
        commandTimeout: Duration = .milliseconds(450)
    ) {
        self.runner = runner
        self.commandTimeout = commandTimeout
    }

    func pauseIfPlaying() async -> Bool {
        let result = await execute("pause-if-playing")
        return result.succeeded && result.output == "PAUSED"
    }

    func play() async -> Bool {
        let result = await execute("play")
        return result.succeeded && result.output == "PLAYED"
    }

    func playbackStateForDiagnostics() async -> MediaPlaybackState {
        Self.playbackState(
            from: await execute("state").output
        )
    }

    static func playbackState(from output: String) -> MediaPlaybackState {
        switch output {
        case "PLAYING":
            .playing
        case "PAUSED":
            .paused
        default:
            .unavailable
        }
    }

    private func execute(
        _ command: String
    ) async -> (output: String, succeeded: Bool) {
        let started = ContinuousClock.now
        let result = await runner.run(
            command: command,
            timeout: commandTimeout
        )
        let output = result.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = (ContinuousClock.now - started).timeInterval

        if result.timedOut {
            mediaPlaybackLogger.error(
                "Adapter command=\(command, privacy: .public) timed out in \(elapsed, format: .fixed(precision: 3), privacy: .public)s"
            )
        } else if result.terminationStatus != 0 {
            mediaPlaybackLogger.error(
                "Adapter command=\(command, privacy: .public) failed status=\(result.terminationStatus ?? -1, privacy: .public) stderrCharacters=\(result.standardError.count, privacy: .public) in \(elapsed, format: .fixed(precision: 3), privacy: .public)s"
            )
        } else {
            mediaPlaybackLogger.info(
                "Adapter command=\(command, privacy: .public) result=\(output, privacy: .public) in \(elapsed, format: .fixed(precision: 3), privacy: .public)s"
            )
        }

        return (
            output,
            !result.timedOut && result.terminationStatus == 0
        )
    }
}

struct MediaRemoteCommandResult: Sendable {
    let terminationStatus: Int32?
    let standardOutput: String
    let standardError: String
    let timedOut: Bool
}

protocol MediaRemoteCommandRunning: Sendable {
    func run(
        command: String,
        timeout: Duration
    ) async -> MediaRemoteCommandResult
}

struct BundledMediaRemoteCommandRunner: MediaRemoteCommandRunning {
    private let runtimeURL: URL?

    init(bundle: Bundle = .main) {
        runtimeURL = bundle.resourceURL?.appending(
            path: "MediaRemoteRuntime"
        )
    }

    init(runtimeURL: URL) {
        self.runtimeURL = runtimeURL
    }

    func run(
        command: String,
        timeout: Duration
    ) async -> MediaRemoteCommandResult {
        guard let runtimeURL else {
            return Self.unavailableResult(
                "Runtime URL is unavailable"
            )
        }

        let scriptURL = runtimeURL.appending(
            path: "mediaremote-adapter.pl"
        )
        let frameworkURL = runtimeURL.appending(
            path: "MediaRemoteAdapter.framework"
        )
        guard FileManager.default.fileExists(atPath: scriptURL.path),
              FileManager.default.fileExists(atPath: frameworkURL.path)
        else {
            return Self.unavailableResult(
                "MediaRemote adapter resources are missing"
            )
        }

        return await MediaRemoteProcessInvocation(
            executableURL: URL(filePath: "/usr/bin/perl"),
            arguments: [
                scriptURL.path,
                frameworkURL.path,
                command
            ]
        ).execute(timeout: timeout)
    }

    private static func unavailableResult(
        _ message: String
    ) -> MediaRemoteCommandResult {
        MediaRemoteCommandResult(
            terminationStatus: nil,
            standardOutput: "",
            standardError: message,
            timedOut: false
        )
    }
}

final class MediaRemoteProcessInvocation: @unchecked Sendable {
    private let process = Process()
    private let standardOutput = Pipe()
    private let standardError = Pipe()
    private let completion = LockedMediaRemoteContinuation()

    init(executableURL: URL, arguments: [String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
    }

    func execute(timeout: Duration) async -> MediaRemoteCommandResult {
        await withCheckedContinuation { continuation in
            completion.install(continuation)
            process.terminationHandler = { [weak self] process in
                self?.finish(process)
            }

            do {
                try process.run()
            } catch {
                finishLaunchFailure(error)
                return
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + timeout.timeInterval
            ) { [weak self] in
                self?.timeOut()
            }
        }
    }

    private func finish(_ process: Process) {
        guard let continuation = completion.claim() else {
            return
        }
        let outputData = standardOutput.fileHandleForReading
            .readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading
            .readDataToEndOfFile()
        continuation.resume(
            returning: MediaRemoteCommandResult(
                terminationStatus: process.terminationStatus,
                standardOutput: String(
                    data: outputData,
                    encoding: .utf8
                ) ?? "",
                standardError: String(
                    data: errorData,
                    encoding: .utf8
                ) ?? "",
                timedOut: false
            )
        )
    }

    private func finishLaunchFailure(_ error: Error) {
        guard let continuation = completion.claim() else {
            return
        }
        continuation.resume(
            returning: MediaRemoteCommandResult(
                terminationStatus: nil,
                standardOutput: "",
                standardError: error.localizedDescription,
                timedOut: false
            )
        )
    }

    private func timeOut() {
        guard let continuation = completion.claim() else {
            return
        }
        let processIdentifier = process.processIdentifier
        if process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .milliseconds(50)
            ) { [self] in
                guard process.isRunning,
                      processIdentifier > 1 else {
                    return
                }
                kill(processIdentifier, SIGKILL)
            }
        }
        continuation.resume(
            returning: MediaRemoteCommandResult(
                terminationStatus: nil,
                standardOutput: "",
                standardError: "MediaRemote adapter timed out",
                timedOut: true
            )
        )
    }
}

private final class LockedMediaRemoteContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<MediaRemoteCommandResult, Never>?
    private var resolved = false

    func install(
        _ continuation:
            CheckedContinuation<MediaRemoteCommandResult, Never>
    ) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func claim() ->
        CheckedContinuation<MediaRemoteCommandResult, Never>?
    {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return nil
        }
        resolved = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        return continuation
    }
}
