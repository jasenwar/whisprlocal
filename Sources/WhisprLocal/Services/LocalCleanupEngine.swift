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
        do {
            try await transport.ensureReady()
            scheduleIdleShutdown()
        } catch {
            localCleanupLogger.error(
                "Prewarm failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func correct(text: String, dictionary: [String]) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalCleanupValidationError.emptyOutput
        }

        let protected = TranscriptProtector.protect(trimmed, dictionary: dictionary)
        let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
        let estimatedInputTokens = max(1, protected.text.utf8.count / 4)
        idleShutdownTask?.cancel()
        let request = LocalCleanupRequest(
            systemPrompt: LocalCleanupPrompt.literal,
            userPrompt: LocalCleanupPrompt.userMessage(
                protectedText: protected.text
            ),
            maximumOutputTokens:
                LocalCleanupRuntimeConfiguration.maximumOutputTokens(
                    estimatedInputTokens: estimatedInputTokens
                )
        )

        do {
            let response = try await DetachedDeadline.run(
                timeout: deadline(wordCount)
            ) { [transport] in
                try await transport.ensureReady()
                return try await transport.complete(request)
            }
            let validated = try validate(
                response.text,
                relativeTo: protected.text
            )
            let restored = try protected.restore(validated)
            scheduleIdleShutdown()
            return DeterministicTranscriptCleanup.finalize(restored)
        } catch is CancellationError {
            await transport.recycle()
            throw CancellationError()
        } catch {
            await transport.recycle()
            localCleanupLogger.error(
                "Request failed and helper was recycled: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    func shutdown() async {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
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
