import Foundation
import OSLog

private let hybridEngineLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "HybridEngine"
)

private enum GroqCleanupAttemptError: LocalizedError {
    case emptyOutput
    case preservation(TranscriptPreservationAssessment)
    case protectedValueChanged

    var errorDescription: String? {
        switch self {
        case .emptyOutput:
            "Groq returned an empty cleanup result."
        case .preservation:
            "Groq cleanup did not pass transcript preservation checks."
        case .protectedValueChanged:
            "Groq cleanup changed a protected transcript value."
        }
    }
}

actor HybridTranscriptionEngine: TranscriptionEngine {
    private let localEngine: any TranscriptionEngine
    private let client: GroqAPIClient
    private let availability: GroqAvailabilityStore
    private let configuration:
        @MainActor @Sendable () -> GroqRuntimeConfiguration

    init(
        localEngine: any TranscriptionEngine,
        client: GroqAPIClient,
        availability: GroqAvailabilityStore,
        configuration: @escaping
            @MainActor @Sendable () -> GroqRuntimeConfiguration
    ) {
        self.localEngine = localEngine
        self.client = client
        self.availability = availability
        self.configuration = configuration
    }

    func transcribe(
        samples: [Float],
        sampleRate: Int,
        hotwords: [String]
    ) async throws -> Transcript {
        let settings = await configuration()
        let scope = GroqRequestScope.transcription(
            settings.transcriptionModel
        )
        guard settings.processingMode == .groqPreferred,
              settings.hasCredential,
              await availability.mayAttempt(scope) else {
            return try await localEngine.transcribe(
                samples: samples,
                sampleRate: sampleRate,
                hotwords: hotwords
            )
        }

        let started = ContinuousClock.now
        do {
            let text = try await client.transcribe(
                samples: samples,
                sampleRate: sampleRate,
                hotwords: hotwords,
                model: settings.transcriptionModel
            )
            await availability.recordSuccess(scope)
            return Transcript(
                text: text,
                engine: "Groq / \(settings.transcriptionModel.rawValue)",
                duration: (ContinuousClock.now - started).timeInterval
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GroqAPIError {
            await availability.recordFailure(error, scope: scope)
            hybridEngineLogger.error(
                "Groq transcription fell back locally: \(error.localizedDescription, privacy: .public)"
            )
            await localEngine.prewarm()
            return try await localEngine.transcribe(
                samples: samples,
                sampleRate: sampleRate,
                hotwords: hotwords
            )
        }
    }

    func prewarm() async {
        let settings = await configuration()
        let groqAvailable = await availability.mayAttempt(
            .transcription(settings.transcriptionModel)
        )
        if settings.processingMode == .fullyLocal
            || !settings.hasCredential
            || !groqAvailable {
            await localEngine.prewarm()
        }
    }

    func releaseIfIdle() async {
        await localEngine.releaseIfIdle()
    }
}

actor HybridCleanupEngine: CleanupEngine {
    private let localEngine: any CleanupEngine
    private let client: GroqAPIClient
    private let availability: GroqAvailabilityStore
    private let configuration:
        @MainActor @Sendable () -> GroqRuntimeConfiguration
    private var lastIdentifier = "Not used"

    init(
        localEngine: any CleanupEngine,
        client: GroqAPIClient,
        availability: GroqAvailabilityStore,
        configuration: @escaping
            @MainActor @Sendable () -> GroqRuntimeConfiguration
    ) {
        self.localEngine = localEngine
        self.client = client
        self.availability = availability
        self.configuration = configuration
    }

    func correct(text: String, dictionary: [String]) async throws -> String {
        try await correct(text: text, dictionary: dictionary, context: nil)
    }

    func correct(
        text: String,
        dictionary: [String],
        context: DictationContext?
    ) async throws -> String {
        let settings = await configuration()
        let primaryScope = GroqRequestScope.cleanup(settings.cleanupModel)
        guard settings.processingMode == .groqPreferred,
              settings.hasCredential,
              await availability.mayAttempt(primaryScope) else {
            let corrected = try await localEngine.correct(
                text: text,
                dictionary: dictionary
            )
            lastIdentifier = await localEngine.lastEngineIdentifier()
            return corrected
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalCleanupValidationError.emptyOutput
        }
        let protected = TranscriptProtector.protect(
            trimmed,
            dictionary: dictionary
        )
        let custom = settings.customCleanupPrompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let systemPrompt = custom.isEmpty ? GroqCleanupPrompt.system : custom
        let userPrompt = GroqCleanupPrompt.userMessage(
            protectedText: protected.text,
            dictionary: dictionary,
            context: context
        )

        do {
            let corrected = try await groqCleanup(
                protected: protected,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: settings.cleanupModel,
                scope: primaryScope
            )
            lastIdentifier = "Groq / \(settings.cleanupModel.rawValue)"
            return corrected
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GroqAPIError {
            await availability.recordFailure(error, scope: primaryScope)
            return try await localFallback(
                text: text,
                dictionary: dictionary,
                reason: error
            )
        } catch let error as GroqCleanupAttemptError {
            logValidationFailure(error, model: settings.cleanupModel)
            return try await safetyRetryOrLocalFallback(
                text: text,
                dictionary: dictionary,
                protected: protected,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                primaryModel: settings.cleanupModel,
                primaryFailure: error
            )
        } catch {
            return try await localFallback(
                text: text,
                dictionary: dictionary,
                reason: error
            )
        }
    }

    func prewarm() async {
        let settings = await configuration()
        let groqAvailable = await availability.mayAttempt(
            .cleanup(settings.cleanupModel)
        )
        if settings.processingMode == .fullyLocal
            || !settings.hasCredential
            || !groqAvailable {
            await localEngine.prewarm()
        }
    }

    func abortPendingWork() async {
        await localEngine.abortPendingWork()
    }

    func shutdown() async {
        await localEngine.shutdown()
    }

    func lastEngineIdentifier() async -> String {
        lastIdentifier
    }

    private func groqCleanup(
        protected: ProtectedTranscript,
        systemPrompt: String,
        userPrompt: String,
        model: GroqCleanupModel,
        scope: GroqRequestScope
    ) async throws -> String {
        let raw = try await client.complete(
            systemPrompt: systemPrompt,
            userText: userPrompt,
            model: model.rawValue,
            maximumTokens: model.maximumCompletionTokens
        )
        await availability.recordSuccess(scope)
        guard raw != "EMPTY" else {
            throw GroqCleanupAttemptError.emptyOutput
        }

        let assessment = TranscriptPreservationValidator.assess(
            original: protected.text,
            cleaned: raw
        )
        guard assessment.isAccepted else {
            throw GroqCleanupAttemptError.preservation(assessment)
        }
        do {
            let restored = try protected.restore(raw)
            return DeterministicTranscriptCleanup.finalize(restored)
        } catch {
            throw GroqCleanupAttemptError.protectedValueChanged
        }
    }

    private func safetyRetryOrLocalFallback(
        text: String,
        dictionary: [String],
        protected: ProtectedTranscript,
        systemPrompt: String,
        userPrompt: String,
        primaryModel: GroqCleanupModel,
        primaryFailure: GroqCleanupAttemptError
    ) async throws -> String {
        let fallbackModel = GroqCleanupModel.qwen36
        let fallbackScope = GroqRequestScope.cleanup(fallbackModel)
        guard primaryModel != fallbackModel,
              await availability.mayAttempt(fallbackScope) else {
            return try await localFallback(
                text: text,
                dictionary: dictionary,
                reason: primaryFailure
            )
        }

        let started = ContinuousClock.now
        hybridEngineLogger.notice(
            "Retrying rejected Groq cleanup with safety model=\(fallbackModel.rawValue, privacy: .public)"
        )
        do {
            let corrected = try await groqCleanup(
                protected: protected,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: fallbackModel,
                scope: fallbackScope
            )
            lastIdentifier = "Groq / \(fallbackModel.rawValue) (safety fallback)"
            hybridEngineLogger.info(
                "Groq safety cleanup accepted model=\(fallbackModel.rawValue, privacy: .public) in \((ContinuousClock.now - started).timeInterval, format: .fixed(precision: 3), privacy: .public)s"
            )
            return corrected
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GroqAPIError {
            await availability.recordFailure(error, scope: fallbackScope)
            return try await localFallback(
                text: text,
                dictionary: dictionary,
                reason: error
            )
        } catch let error as GroqCleanupAttemptError {
            logValidationFailure(error, model: fallbackModel)
            return try await localFallback(
                text: text,
                dictionary: dictionary,
                reason: error
            )
        } catch {
            return try await localFallback(
                text: text,
                dictionary: dictionary,
                reason: error
            )
        }
    }

    private nonisolated func logValidationFailure(
        _ error: GroqCleanupAttemptError,
        model: GroqCleanupModel
    ) {
        switch error {
        case .preservation(let assessment):
            hybridEngineLogger.notice(
                "Groq cleanup rejected model=\(model.rawValue, privacy: .public) reason=\(assessment.rejectionReason?.rawValue ?? "unknown", privacy: .public) originalSentences=\(assessment.originalSentenceCount, privacy: .public) cleanedSentences=\(assessment.cleanedSentenceCount, privacy: .public) significantTokens=\(assessment.originalSignificantTokenCount, privacy: .public) retainedTokens=\(assessment.retainedSignificantTokenCount, privacy: .public) missingTokens=\(assessment.missingSignificantTokenCount, privacy: .public) retainedRatio=\(assessment.retainedTokenRatio, format: .fixed(precision: 3), privacy: .public)"
            )
        case .emptyOutput:
            hybridEngineLogger.notice(
                "Groq cleanup rejected model=\(model.rawValue, privacy: .public) reason=empty_output"
            )
        case .protectedValueChanged:
            hybridEngineLogger.notice(
                "Groq cleanup rejected model=\(model.rawValue, privacy: .public) reason=protected_value_changed"
            )
        }
    }

    private func localFallback(
        text: String,
        dictionary: [String],
        reason: Error
    ) async throws -> String {
        hybridEngineLogger.error(
            "Groq cleanup fell back locally: \(reason.localizedDescription, privacy: .public)"
        )
        await localEngine.prewarm()
        let corrected = try await localEngine.correct(
            text: text,
            dictionary: dictionary
        )
        lastIdentifier = await localEngine.lastEngineIdentifier()
        return corrected
    }
}
