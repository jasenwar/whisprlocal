import Foundation
import XCTest
@testable import WhisprLocal

final class GroqHybridTests: XCTestCase {
    func testCredentialStateRejectsAStaleKeychainLoad() {
        let state = GroqCredentialState()
        let loadRevision = state.currentRevision

        state.set("  gsk_new  ")
        let acceptedStaleLoad = state.setIfUnchanged(
            "gsk_old",
            since: loadRevision
        )

        XCTAssertFalse(acceptedStaleLoad)
        XCTAssertEqual(state.apiKey, "gsk_new")
    }

    func testFullyLocalTranscriptionMakesNoNetworkRequest() async throws {
        let transport = MockGroqTransport(responses: [
            .success(status: 200, body: #"{"text":"cloud transcript"}"#)
        ])
        let local = StubTranscriptionEngine(text: "local transcript")
        let availability = makeAvailabilityStore()
        let engine = HybridTranscriptionEngine(
            localEngine: local,
            client: GroqAPIClient(
                apiKeyProvider: { "gsk_test" },
                transport: transport
            ),
            availability: availability,
            configuration: configuration(mode: .fullyLocal)
        )

        let transcript = try await engine.transcribe(
            samples: [0.1, 0.2],
            sampleRate: 16_000,
            hotwords: []
        )

        XCTAssertEqual(transcript.text, "local transcript")
        XCTAssertEqual(transport.requestCount, 0)
        let localCount = await local.transcriptionCount
        XCTAssertEqual(localCount, 1)
    }

    func testMissingCredentialFallsBackWithoutNetworkRequest() async throws {
        let transport = MockGroqTransport(responses: [])
        let local = StubTranscriptionEngine(text: "local transcript")
        let engine = HybridTranscriptionEngine(
            localEngine: local,
            client: GroqAPIClient(
                apiKeyProvider: { nil },
                transport: transport
            ),
            availability: makeAvailabilityStore(),
            configuration: configuration(
                mode: .groqPreferred,
                hasCredential: false
            )
        )

        _ = try await engine.transcribe(
            samples: [0.1],
            sampleRate: 16_000,
            hotwords: []
        )

        XCTAssertEqual(transport.requestCount, 0)
        let localCount = await local.transcriptionCount
        XCTAssertEqual(localCount, 1)
    }

    func testGroqTranscriptionIsPreferredWhenAvailable() async throws {
        let transport = MockGroqTransport(responses: [
            .success(status: 200, body: #"{"text":"cloud transcript"}"#)
        ])
        let local = StubTranscriptionEngine(text: "local transcript")
        let engine = HybridTranscriptionEngine(
            localEngine: local,
            client: GroqAPIClient(
                apiKeyProvider: { "gsk_test" },
                transport: transport
            ),
            availability: makeAvailabilityStore(),
            configuration: configuration(mode: .groqPreferred)
        )

        let transcript = try await engine.transcribe(
            samples: [0.1],
            sampleRate: 16_000,
            hotwords: ["Jasen"]
        )

        XCTAssertEqual(transcript.text, "cloud transcript")
        XCTAssertTrue(transcript.engine.contains("Groq"))
        XCTAssertEqual(transport.requestCount, 1)
        let localCount = await local.transcriptionCount
        XCTAssertEqual(localCount, 0)
    }

    func testRateLimitFallsBackAndSkipsGroqDuringCooldown() async throws {
        let transport = MockGroqTransport(responses: [
            .success(
                status: 429,
                body: #"{"error":{"message":"requests per day exceeded"}}"#
            )
        ])
        let local = StubTranscriptionEngine(text: "local transcript")
        let availability = makeAvailabilityStore()
        let engine = HybridTranscriptionEngine(
            localEngine: local,
            client: GroqAPIClient(
                apiKeyProvider: { "gsk_test" },
                transport: transport
            ),
            availability: availability,
            configuration: configuration(mode: .groqPreferred)
        )

        for _ in 0..<2 {
            _ = try await engine.transcribe(
                samples: [0.1],
                sampleRate: 16_000,
                hotwords: []
            )
        }

        XCTAssertEqual(transport.requestCount, 1)
        let localCount = await local.transcriptionCount
        XCTAssertEqual(localCount, 2)
        let snapshot = await availability.snapshot(hasCredential: true)
        XCTAssertEqual(snapshot.state, .temporarilyUnavailable)
    }

    func testGroqCleanupReturnsValidatedTranscript() async throws {
        let transport = MockGroqTransport(responses: [
            .success(
                status: 200,
                body: #"{"choices":[{"message":{"content":"This is a test."}}]}"#
            )
        ])
        let local = StubCleanupEngine(result: "local cleanup")
        let engine = HybridCleanupEngine(
            localEngine: local,
            client: GroqAPIClient(
                apiKeyProvider: { "gsk_test" },
                transport: transport
            ),
            availability: makeAvailabilityStore(),
            configuration: configuration(mode: .groqPreferred)
        )

        let result = try await engine.correct(
            text: "this is a test",
            dictionary: []
        )

        XCTAssertEqual(result, "This is a test.")
        XCTAssertEqual(transport.requestCount, 1)
        let correctionCount = await local.correctionCount
        let identifier = await engine.lastEngineIdentifier()
        XCTAssertEqual(correctionCount, 0)
        XCTAssertTrue(identifier.contains("Groq"))
        XCTAssertEqual(
            transport.lastJSONBody?["max_completion_tokens"] as? Int,
            4_096
        )
    }

    func testRejectedGPTCleanupRetriesGroqQwenBeforeLocalFallback() async throws {
        let transport = MockGroqTransport(responses: [
            .success(
                status: 200,
                body: #"{"choices":[{"message":{"content":"What do you think based off the logs and testing?"}}]}"#
            ),
            .success(
                status: 200,
                body: #"{"choices":[{"message":{"content":"Could this be made better? What do you think based off the logs and testing?"}}]}"#
            ),
        ])
        let local = StubCleanupEngine(result: "local cleanup")
        let engine = HybridCleanupEngine(
            localEngine: local,
            client: GroqAPIClient(
                apiKeyProvider: { "gsk_test" },
                transport: transport
            ),
            availability: makeAvailabilityStore(),
            configuration: configuration(mode: .groqPreferred)
        )

        let result = try await engine.correct(
            text: "Could this be made better? What do you think based off the logs and testing?",
            dictionary: []
        )

        XCTAssertEqual(
            result,
            "Could this be made better? What do you think based off the logs and testing?"
        )
        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertEqual(
            transport.requestedModels,
            [
                GroqCleanupModel.gptOSS20B.rawValue,
                GroqCleanupModel.qwen36.rawValue,
            ]
        )
        let correctionCount = await local.correctionCount
        let identifier = await engine.lastEngineIdentifier()
        XCTAssertEqual(correctionCount, 0)
        XCTAssertTrue(identifier.contains("safety fallback"))
    }

    func testBothRejectedGroqCleanupsUseLocalFallback() async throws {
        let rejected = #"{"choices":[{"message":{"content":"What do you think based off the logs and testing?"}}]}"#
        let transport = MockGroqTransport(responses: [
            .success(status: 200, body: rejected),
            .success(status: 200, body: rejected),
        ])
        let local = StubCleanupEngine(result: "local cleanup")
        let engine = HybridCleanupEngine(
            localEngine: local,
            client: GroqAPIClient(
                apiKeyProvider: { "gsk_test" },
                transport: transport
            ),
            availability: makeAvailabilityStore(),
            configuration: configuration(mode: .groqPreferred)
        )

        let result = try await engine.correct(
            text: "Could this be made better? What do you think based off the logs and testing?",
            dictionary: []
        )

        XCTAssertEqual(result, "local cleanup")
        XCTAssertEqual(transport.requestCount, 2)
        let correctionCount = await local.correctionCount
        XCTAssertEqual(correctionCount, 1)
    }

    func testSelectedQwenDoesNotRetryItselfAfterRejection() async throws {
        let transport = MockGroqTransport(responses: [
            .success(
                status: 200,
                body: #"{"choices":[{"message":{"content":"What do you think based off the logs and testing?"}}]}"#
            )
        ])
        let local = StubCleanupEngine(result: "local cleanup")
        let engine = HybridCleanupEngine(
            localEngine: local,
            client: GroqAPIClient(
                apiKeyProvider: { "gsk_test" },
                transport: transport
            ),
            availability: makeAvailabilityStore(),
            configuration: configuration(
                mode: .groqPreferred,
                cleanupModel: .qwen36
            )
        )

        let result = try await engine.correct(
            text: "Could this be made better? What do you think based off the logs and testing?",
            dictionary: []
        )

        XCTAssertEqual(result, "local cleanup")
        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertEqual(
            transport.requestedModels,
            [GroqCleanupModel.qwen36.rawValue]
        )
        let correctionCount = await local.correctionCount
        XCTAssertEqual(correctionCount, 1)
    }

    func testHarmlessSentenceMergeDoesNotTriggerSafetyRetry() async throws {
        let transport = MockGroqTransport(responses: [
            .success(
                status: 200,
                body: #"{"choices":[{"message":{"content":"Please send the report, then restart the server."}}]}"#
            )
        ])
        let local = StubCleanupEngine(result: "local cleanup")
        let engine = HybridCleanupEngine(
            localEngine: local,
            client: GroqAPIClient(
                apiKeyProvider: { "gsk_test" },
                transport: transport
            ),
            availability: makeAvailabilityStore(),
            configuration: configuration(mode: .groqPreferred)
        )

        let result = try await engine.correct(
            text: "Please send the report. Then restart the server.",
            dictionary: []
        )

        XCTAssertEqual(
            result,
            "Please send the report, then restart the server."
        )
        XCTAssertEqual(transport.requestCount, 1)
        let correctionCount = await local.correctionCount
        XCTAssertEqual(correctionCount, 0)
    }

    func testLengthLimitedEmptyCompletionHasSpecificError() async throws {
        let transport = MockGroqTransport(responses: [
            .success(
                status: 200,
                body: #"{"choices":[{"finish_reason":"length","message":{"content":""}}],"usage":{"prompt_tokens":80,"completion_tokens":96}}"#
            )
        ])
        let client = GroqAPIClient(
            apiKeyProvider: { "gsk_test" },
            transport: transport
        )

        do {
            _ = try await client.complete(
                systemPrompt: "Clean dictation.",
                userText: "hello",
                model: GroqCleanupModel.gptOSS20B.rawValue,
                maximumTokens: 96
            )
            XCTFail("Expected completion budget error")
        } catch let error as GroqAPIError {
            XCTAssertEqual(error, .completionBudgetExhausted)
        }
    }

    func testEmptyCompletionDoesNotBlockIndependentGroqRequests() async {
        let availability = makeAvailabilityStore()
        let scope = GroqRequestScope.cleanup(.gptOSS20B)

        await availability.recordFailure(.emptyResponse, scope: scope)

        let mayAttempt = await availability.mayAttempt(scope)
        XCTAssertTrue(mayAttempt)
        let snapshot = await availability.snapshot(hasCredential: true)
        XCTAssertEqual(snapshot.state, .ready)
    }

    func testCompletionBudgetErrorDoesNotBlockIndependentGroqRequests() async {
        let availability = makeAvailabilityStore()
        let scope = GroqRequestScope.cleanup(.gptOSS20B)

        await availability.recordFailure(
            .completionBudgetExhausted,
            scope: scope
        )

        let mayAttempt = await availability.mayAttempt(scope)
        XCTAssertTrue(mayAttempt)
        let snapshot = await availability.snapshot(hasCredential: true)
        XCTAssertEqual(snapshot.state, .ready)
    }

    func testRateLimitBlocksOnlyTheAffectedCapabilityAndModel() async {
        let availability = makeAvailabilityStore()
        let transcription = GroqRequestScope.transcription(.whisperLargeV3)
        let cleanup = GroqRequestScope.cleanup(.gptOSS20B)

        await availability.recordFailure(
            .rateLimited(retryAfter: 120, dailyLimit: false),
            scope: transcription
        )

        let transcriptionAllowed = await availability.mayAttempt(transcription)
        let cleanupAllowed = await availability.mayAttempt(cleanup)
        let contextAllowed = await availability.mayAttempt(.context)
        XCTAssertFalse(transcriptionAllowed)
        XCTAssertTrue(cleanupAllowed)
        XCTAssertTrue(contextAllowed)
    }

    func testForbiddenGPTCleanupDoesNotBlockQwenCleanup() async {
        let availability = makeAvailabilityStore()
        let gpt = GroqRequestScope.cleanup(.gptOSS20B)
        let qwen = GroqRequestScope.cleanup(.qwen36)

        await availability.recordFailure(.forbidden, scope: gpt)

        let gptAllowed = await availability.mayAttempt(gpt)
        let qwenAllowed = await availability.mayAttempt(qwen)
        let contextAllowed = await availability.mayAttempt(.context)
        XCTAssertFalse(gptAllowed)
        XCTAssertTrue(qwenAllowed)
        XCTAssertTrue(contextAllowed)
    }

    func testUnauthorizedCredentialBlocksEveryGroqCapability() async {
        let availability = makeAvailabilityStore()

        await availability.recordFailure(
            .unauthorized,
            scope: .cleanup(.gptOSS20B)
        )

        let transcriptionAllowed = await availability.mayAttempt(
            .transcription(.whisperLargeV3)
        )
        let cleanupAllowed = await availability.mayAttempt(.cleanup(.qwen36))
        let contextAllowed = await availability.mayAttempt(.context)
        XCTAssertFalse(transcriptionAllowed)
        XCTAssertFalse(cleanupAllowed)
        XCTAssertFalse(contextAllowed)
    }

    func testScopedModelBlockPersistsWithoutBecomingGlobal() async {
        let suite = "GroqHybridTests.Persistence.\(UUID().uuidString)"
        let gpt = GroqRequestScope.cleanup(.gptOSS20B)

        let original = GroqAvailabilityStore(
            defaults: UserDefaults(suiteName: suite)!
        )
        await original.recordFailure(.forbidden, scope: gpt)
        let restored = GroqAvailabilityStore(
            defaults: UserDefaults(suiteName: suite)!
        )

        let gptAllowed = await restored.mayAttempt(gpt)
        let transcriptionAllowed = await restored.mayAttempt(
            .transcription(.whisperLargeV3)
        )
        let contextAllowed = await restored.mayAttempt(.context)
        XCTAssertFalse(gptAllowed)
        XCTAssertTrue(transcriptionAllowed)
        XCTAssertTrue(contextAllowed)

        await restored.credentialChanged()
        let allowedAfterCredentialChange = await restored.mayAttempt(gpt)
        XCTAssertTrue(allowedAfterCredentialChange)
    }

    func testWAVEncoderProducesPCMMonoHeader() {
        let data = WAVEncoder.pcm16Mono(
            samples: [0, 0.5, -0.5],
            sampleRate: 16_000
        )

        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(data.count, 44 + 3 * MemoryLayout<Int16>.size)
    }

    private func configuration(
        mode: ProcessingMode,
        hasCredential: Bool = true,
        cleanupModel: GroqCleanupModel = .gptOSS20B
    ) -> @MainActor @Sendable () -> GroqRuntimeConfiguration {
        {
            GroqRuntimeConfiguration(
                processingMode: mode,
                hasCredential: hasCredential,
                transcriptionModel: .whisperLargeV3,
                cleanupModel: cleanupModel,
                customCleanupPrompt: ""
            )
        }
    }

    private func makeAvailabilityStore() -> GroqAvailabilityStore {
        let suite = "GroqHybridTests.\(UUID().uuidString)"
        return GroqAvailabilityStore(
            defaults: UserDefaults(suiteName: suite)!
        )
    }
}

private final class MockGroqTransport: GroqHTTPTransport, @unchecked Sendable {
    struct Response {
        let status: Int
        let body: Data

        static func success(status: Int, body: String) -> Response {
            Response(status: status, body: Data(body.utf8))
        }
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var count = 0
    private var jsonBodies: [[String: Any]] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    var requestCount: Int {
        lock.withLock { count }
    }

    var lastJSONBody: [String: Any]? {
        lock.withLock { jsonBodies.last }
    }

    var requestedModels: [String] {
        lock.withLock {
            jsonBodies.compactMap { $0["model"] as? String }
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try lock.withLock {
            count += 1
            if let body = request.httpBody,
               let object = try? JSONSerialization.jsonObject(with: body)
                    as? [String: Any] {
                jsonBodies.append(object)
            }
            guard !responses.isEmpty else {
                throw GroqAPIError.requestFailed
            }
            let response = responses.removeFirst()
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response.body, http)
        }
    }
}

private actor StubTranscriptionEngine: TranscriptionEngine {
    private let text: String
    private(set) var transcriptionCount = 0

    init(text: String) {
        self.text = text
    }

    func transcribe(
        samples: [Float],
        sampleRate: Int,
        hotwords: [String]
    ) -> Transcript {
        transcriptionCount += 1
        return Transcript(text: text, engine: "local", duration: 0)
    }

    func prewarm() {}
    func releaseIfIdle() {}
}

private actor StubCleanupEngine: CleanupEngine {
    private let result: String
    private(set) var correctionCount = 0

    init(result: String) {
        self.result = result
    }

    func correct(text: String, dictionary: [String]) -> String {
        correctionCount += 1
        return result
    }

    func lastEngineIdentifier() -> String { "Local test cleanup" }
}
