import Darwin
import Foundation
import XCTest
@testable import WhisprLocal

final class DictationPipelineTests: XCTestCase {
    func testPipelineRunsBothEnginesWhileMainActorIsBusy() async throws {
        let events = PipelineEventRecorder()
        let startGate = PipelineStartGate()
        let pipeline = DictationPipeline(
            transcriptionEngine: RecordingTranscriptionEngine(
                events: events,
                delay: .milliseconds(20)
            ),
            cleanupEngine: RecordingCleanupEngine(
                events: events,
                delay: .milliseconds(20)
            )
        )
        let request = DictationPipelineRequest(
            samples: Array(repeating: 0.1, count: 16_000),
            hotwords: [],
            dictionary: [],
            snippets: [],
            cleanupEnabled: true,
            cleanupWarmupTask: nil
        )

        let task = Task.detached(priority: .userInitiated) {
            await startGate.wait()
            return try await pipeline.run(request: request) { _ in
                events.append("progress")
            }
        }

        await startGate.open()
        await MainActor.run {
            blockCurrentThread(forMicroseconds: 150_000)
        }

        XCTAssertEqual(
            events.values,
            [
                "transcription-start",
                "transcription-finished",
                "progress",
                "cleanup-start",
                "cleanup-finished",
            ]
        )
        let output = try await task.value
        XCTAssertEqual(output.transcript.text, "raw text")
        XCTAssertEqual(output.correctedText, "Cleaned text.")
        XCTAssertNil(output.cleanupFallbackDescription)
    }

    func testCleanupFailureReturnsRecoverableRawTranscript() async throws {
        let pipeline = DictationPipeline(
            transcriptionEngine: RecordingTranscriptionEngine(
                events: PipelineEventRecorder(),
                delay: .zero
            ),
            cleanupEngine: FailingCleanupEngine()
        )
        let request = DictationPipelineRequest(
            samples: Array(repeating: 0.1, count: 16_000),
            hotwords: [],
            dictionary: [],
            snippets: [],
            cleanupEnabled: true,
            cleanupWarmupTask: nil
        )

        let output = try await pipeline.run(request: request) { _ in }

        XCTAssertEqual(output.transcript.text, "raw text")
        XCTAssertEqual(output.correctedText, "raw text")
        XCTAssertEqual(
            output.cleanupFallbackDescription,
            WhisprLocalError.cleanupTimedOut.localizedDescription
        )
        XCTAssertEqual(output.cleanupEngineIdentifier, "raw fallback")
    }

    func testPipelineCancellationStopsBeforeCleanup() async {
        let events = PipelineEventRecorder()
        let pipeline = DictationPipeline(
            transcriptionEngine: RecordingTranscriptionEngine(
                events: events,
                delay: .seconds(1)
            ),
            cleanupEngine: RecordingCleanupEngine(
                events: events,
                delay: .zero
            )
        )
        let request = DictationPipelineRequest(
            samples: Array(repeating: 0.1, count: 16_000),
            hotwords: [],
            dictionary: [],
            snippets: [],
            cleanupEnabled: true,
            cleanupWarmupTask: nil
        )
        let task = Task.detached {
            try await pipeline.run(request: request) { _ in }
        }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(events.values.contains("cleanup-start"))
    }
}

private actor PipelineStartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}

private func blockCurrentThread(forMicroseconds duration: useconds_t) {
    usleep(duration)
}

private final class PipelineEventRecorder: @unchecked Sendable {
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

private actor RecordingTranscriptionEngine: TranscriptionEngine {
    private let events: PipelineEventRecorder
    private let delay: Duration

    init(events: PipelineEventRecorder, delay: Duration) {
        self.events = events
        self.delay = delay
    }

    func transcribe(
        samples: [Float],
        sampleRate: Int,
        hotwords: [String]
    ) async throws -> Transcript {
        events.append("transcription-start")
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        events.append("transcription-finished")
        return Transcript(
            text: "raw text",
            engine: "test transcription",
            duration: delay.timeInterval
        )
    }

    func prewarm() {}
    func releaseIfIdle() {}
}

private actor RecordingCleanupEngine: CleanupEngine {
    private let events: PipelineEventRecorder
    private let delay: Duration

    init(events: PipelineEventRecorder, delay: Duration) {
        self.events = events
        self.delay = delay
    }

    func correct(
        text: String,
        dictionary: [String]
    ) async throws -> String {
        events.append("cleanup-start")
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        events.append("cleanup-finished")
        return "Cleaned text."
    }
}

private actor FailingCleanupEngine: CleanupEngine {
    func correct(
        text: String,
        dictionary: [String]
    ) throws -> String {
        throw WhisprLocalError.cleanupTimedOut
    }
}
