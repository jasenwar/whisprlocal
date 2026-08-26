import Foundation
import OSLog

private let dictationPipelineLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "Pipeline"
)

struct DictationPipelineRequest: Sendable {
    let samples: [Float]
    let hotwords: [HotwordPhrase]
    let dictionary: [String]
    let vocabularyEntries: [DictionaryEntry]
    let snippets: [Snippet]
    let cleanupEnabled: Bool
    let contextTask: Task<DictationContext?, Never>?
    let cleanupWarmupTask: Task<Void, Never>?

    init(
        samples: [Float],
        hotwords: [HotwordPhrase],
        dictionary: [String],
        vocabularyEntries: [DictionaryEntry] = [],
        snippets: [Snippet],
        cleanupEnabled: Bool,
        contextTask: Task<DictationContext?, Never>? = nil,
        cleanupWarmupTask: Task<Void, Never>?
    ) {
        self.samples = samples
        self.hotwords = hotwords
        self.dictionary = dictionary
        self.vocabularyEntries = vocabularyEntries
        self.snippets = snippets
        self.cleanupEnabled = cleanupEnabled
        self.contextTask = contextTask
        self.cleanupWarmupTask = cleanupWarmupTask
    }
}

struct DictationPipelineProgress: Sendable {
    let transcript: Transcript
    let emittedAt: ContinuousClock.Instant
}

struct DictationPipelineOutput: Sendable {
    let transcript: Transcript
    let correctedText: String
    let cleanupEngineIdentifier: String
    let cleanupFallbackDescription: String?
    let appliedVocabularyEntryIDs: [Int64]
    let startedAt: ContinuousClock.Instant
    let completedAt: ContinuousClock.Instant
}

struct DictationPipeline: Sendable {
    private let transcriptionEngine: any TranscriptionEngine
    private let cleanupEngine: any CleanupEngine

    init(
        transcriptionEngine: any TranscriptionEngine,
        cleanupEngine: any CleanupEngine
    ) {
        self.transcriptionEngine = transcriptionEngine
        self.cleanupEngine = cleanupEngine
    }

    func run(
        request: DictationPipelineRequest,
        onProgress: @escaping @Sendable (DictationPipelineProgress) -> Void
    ) async throws -> DictationPipelineOutput {
        let startedAt = ContinuousClock.now
        let transcriptionStarted = ContinuousClock.now
        let transcript = try await transcriptionEngine.transcribe(
            samples: request.samples,
            sampleRate: 16_000,
            hotwordPhrases: request.hotwords
        )
        let transcriptionReceivedAt = ContinuousClock.now
        let transcriptionWallSeconds = (
            transcriptionReceivedAt - transcriptionStarted
        ).timeInterval
        dictationPipelineLogger.info(
            "Pipeline received transcript: wallSeconds=\(transcriptionWallSeconds, format: .fixed(precision: 3), privacy: .public) decodeSeconds=\(transcript.duration, format: .fixed(precision: 3), privacy: .public) nonDecodeSeconds=\(max(0, transcriptionWallSeconds - transcript.duration), format: .fixed(precision: 3), privacy: .public)"
        )
        onProgress(
            DictationPipelineProgress(
                transcript: transcript,
                emittedAt: transcriptionReceivedAt
            )
        )
        try Task.checkCancellation()

        let vocabularyResolution = VocabularyResolver.resolve(
            transcript.text,
            entries: request.vocabularyEntries
        )
        var corrected = vocabularyResolution.text
        var cleanupIdentifier = "raw fallback"
        var cleanupFallbackDescription: String?

        if request.cleanupEnabled {
            let protectedVocabulary = request.dictionary
                + request.snippets.map(\.trigger)
            let wordCount = vocabularyResolution.text
                .split(whereSeparator: \.isWhitespace)
                .count
            let cleanupDeadline =
                LocalCleanupRuntimeConfiguration.endToEndDeadline(
                    wordCount: wordCount
                )
            let cleanupStarted = ContinuousClock.now
            dictationPipelineLogger.info(
                "Pipeline cleanup started: endToEndDeadline=\(cleanupDeadline.timeInterval, format: .fixed(precision: 3), privacy: .public)s warmupPending=\(request.cleanupWarmupTask != nil, privacy: .public)"
            )
            do {
                let context = await contextForCleanup(
                    from: request.contextTask
                )
                corrected = try await BoundedCleanupExecutor.correct(
                    using: cleanupEngine,
                    warmupTask: request.cleanupWarmupTask,
                    text: vocabularyResolution.text,
                    dictionary: protectedVocabulary,
                    context: context,
                    timeout: cleanupDeadline
                )
                let cleanupSeconds = (
                    ContinuousClock.now - cleanupStarted
                ).timeInterval
                dictationPipelineLogger.info(
                    "Pipeline received cleanup result in \(cleanupSeconds, format: .fixed(precision: 3), privacy: .public)s"
                )
                cleanupIdentifier = await cleanupEngine.lastEngineIdentifier()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                cleanupFallbackDescription = error.localizedDescription
                dictationPipelineLogger.error(
                    "Pipeline cleanup fell back to raw text after \((ContinuousClock.now - cleanupStarted).timeInterval, format: .fixed(precision: 3), privacy: .public)s: \(error.localizedDescription, privacy: .public)"
                )
            }
        } else {
            cleanupIdentifier = "disabled"
        }

        try Task.checkCancellation()
        corrected = SnippetExpander.expand(
            corrected,
            snippets: request.snippets
        )
        let completedAt = ContinuousClock.now
        dictationPipelineLogger.info(
            "Background pipeline completed in \((completedAt - startedAt).timeInterval, format: .fixed(precision: 3), privacy: .public)s"
        )
        return DictationPipelineOutput(
            transcript: transcript,
            correctedText: corrected,
            cleanupEngineIdentifier: cleanupIdentifier,
            cleanupFallbackDescription: cleanupFallbackDescription,
            appliedVocabularyEntryIDs:
                vocabularyResolution.appliedEntryIDs,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func contextForCleanup(
        from task: Task<DictationContext?, Never>?
    ) async -> DictationContext? {
        guard let task else { return nil }
        do {
            return try await DetachedDeadline.run(
                timeout: .milliseconds(400)
            ) {
                await task.value
            }
        } catch {
            task.cancel()
            dictationPipelineLogger.info(
                "Context was not ready within 0.4s; continuing without it"
            )
            return nil
        }
    }
}
