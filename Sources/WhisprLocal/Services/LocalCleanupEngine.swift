import Foundation
import OSLog

private let localCleanupLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "LocalCleanup"
)

actor LocalCleanupEngine: CleanupEngine {
    private let transport: any LocalCleanupTransport
    private let deadline: @Sendable (Int) -> Duration
    private var idleShutdownTask: Task<Void, Never>?
    private var warmedGeneration: UInt64?

    init(
        transport: any LocalCleanupTransport,
        deadline: @escaping @Sendable (Int) -> Duration = {
            LocalCleanupRuntimeConfiguration.requestDeadline(wordCount: $0)
        }
    ) {
        self.transport = transport
        self.deadline = deadline
    }

    func prewarm() async {
        idleShutdownTask?.cancel()
        defer { scheduleIdleShutdown() }
        let started = ContinuousClock.now
        do {
            let generation = try await transport.ensureReady()
            if warmedGeneration != generation {
                let warmupRequest = LocalCleanupRequest(
                    systemPrompt: LocalCleanupPrompt.literal,
                    userPrompt: LocalCleanupPrompt.userMessage(
                        protectedText: "warmup"
                    ),
                    maximumOutputTokens: 24
                )
                let response = try await DetachedDeadline.run(
                    timeout: .seconds(2.5)
                ) { [transport] in
                    try await transport.complete(warmupRequest)
                }
                warmedGeneration = generation
                localCleanupLogger.info(
                    "Prompt cache seeded generation=\(generation, privacy: .public) cachedTokens=\(response.cachedPromptTokens ?? -1, privacy: .public) in \((ContinuousClock.now - started).timeInterval, format: .fixed(precision: 3), privacy: .public)s"
                )
            } else {
                localCleanupLogger.info(
                    "Prewarm reused generation=\(generation, privacy: .public) in \((ContinuousClock.now - started).timeInterval, format: .fixed(precision: 3), privacy: .public)s"
                )
            }
        } catch is CancellationError {
            localCleanupLogger.info("Prewarm was cancelled")
            return
        } catch {
            localCleanupLogger.error(
                "Prewarm failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func correct(text: String, dictionary: [String]) async throws -> String {
        try Task.checkCancellation()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalCleanupValidationError.emptyOutput
        }

        let protected = TranscriptProtector.protect(trimmed, dictionary: dictionary)
        let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
        let estimatedInputTokens = max(1, protected.text.utf8.count / 4)
        let userPrompt = LocalCleanupPrompt.userMessage(
            protectedText: protected.text
        )
        let maximumOutputTokens =
            LocalCleanupRuntimeConfiguration.maximumOutputTokens(
                estimatedInputTokens: estimatedInputTokens
            )
        guard LocalCleanupRuntimeConfiguration.requestFitsContext(
            systemPrompt: LocalCleanupPrompt.literal,
            userPrompt: userPrompt,
            maximumOutputTokens: maximumOutputTokens
        ) else {
            throw LocalCleanupValidationError.inputTooLong
        }
        idleShutdownTask?.cancel()
        let request = LocalCleanupRequest(
            systemPrompt: LocalCleanupPrompt.literal,
            userPrompt: userPrompt,
            maximumOutputTokens: maximumOutputTokens
        )
        let requestDeadline = deadline(wordCount)
        let started = ContinuousClock.now
        localCleanupLogger.info(
            "Request entered cleanup actor words=\(wordCount, privacy: .public) requestDeadline=\(requestDeadline.timeInterval, format: .fixed(precision: 3), privacy: .public)s maximumOutputTokens=\(maximumOutputTokens, privacy: .public)"
        )

        do {
            let (generation, response) = try await DetachedDeadline.run(
                timeout: requestDeadline
            ) { [transport] in
                let generation = try await transport.ensureReady()
                try Task.checkCancellation()
                let response = try await transport.complete(request)
                return (generation, response)
            }
            let validated = try validate(
                response.text,
                relativeTo: protected.text
            )
            let restored = try protected.restore(validated)
            warmedGeneration = generation
            scheduleIdleShutdown()
            localCleanupLogger.info(
                "Request validated generation=\(generation, privacy: .public) cachedTokens=\(response.cachedPromptTokens ?? -1, privacy: .public) in \((ContinuousClock.now - started).timeInterval, format: .fixed(precision: 3), privacy: .public)s"
            )
            return DeterministicTranscriptCleanup.finalize(restored)
        } catch WhisprLocalError.cleanupTimedOut {
            warmedGeneration = nil
            await transport.recycleAfterTimeout()
            localCleanupLogger.error(
                "Request timed out and helper was recycled"
            )
            throw WhisprLocalError.cleanupTimedOut
        } catch is CancellationError {
            warmedGeneration = nil
            await transport.recycleAfterTimeout()
            throw CancellationError()
        } catch {
            warmedGeneration = nil
            await transport.recycle()
            localCleanupLogger.error(
                "Request failed and helper was recycled: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    func abortPendingWork() async {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        warmedGeneration = nil
        await transport.recycleAfterTimeout()
        localCleanupLogger.error(
            "Pending cleanup work aborted and helper recycled"
        )
    }

    func shutdown() async {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        warmedGeneration = nil
        await transport.shutdown()
    }

    private func scheduleIdleShutdown() {
        idleShutdownTask?.cancel()
        idleShutdownTask = Task { [transport] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            await transport.shutdown()
        }
    }

    private func validate(_ output: String, relativeTo input: String) throws -> String {
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw LocalCleanupValidationError.emptyOutput
        }
        guard cleaned.count <= max(1_000, input.count * 3),
              cleaned.count >= max(1, input.count / 5)
        else {
            throw LocalCleanupValidationError.invalidLength
        }

        let lowercased = cleaned.lowercased()
        let forbiddenPrefixes = [
            "cleaned transcript:",
            "cleaned text:",
            "output:",
            "here is",
            "here's"
        ]
        guard !forbiddenPrefixes.contains(where: lowercased.hasPrefix),
              !cleaned.contains("```"),
              !cleaned.contains("BEGIN_TRANSCRIPT"),
              !cleaned.contains("END_TRANSCRIPT")
        else {
            throw LocalCleanupValidationError.unexpectedFormatting
        }
        return cleaned
    }
}

enum BoundedCleanupExecutor {
    static func correct(
        using engine: any CleanupEngine,
        warmupTask: Task<Void, Never>?,
        text: String,
        dictionary: [String],
        timeout: Duration
    ) async throws -> String {
        do {
            return try await DetachedDeadline.run(timeout: timeout) {
                await warmupTask?.value
                try Task.checkCancellation()
                return try await engine.correct(
                    text: text,
                    dictionary: dictionary
                )
            }
        } catch WhisprLocalError.cleanupTimedOut {
            Task.detached(priority: .userInitiated) {
                await engine.abortPendingWork()
            }
            throw WhisprLocalError.cleanupTimedOut
        } catch is CancellationError {
            Task.detached(priority: .userInitiated) {
                await engine.abortPendingWork()
            }
            throw CancellationError()
        }
    }
}
