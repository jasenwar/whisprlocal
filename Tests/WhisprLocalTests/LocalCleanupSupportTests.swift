import Foundation
import CryptoKit
import XCTest
@testable import WhisprLocal

final class LocalCleanupSupportTests: XCTestCase {
    func testDeterministicFinalizerCapitalizesAndTerminatesSentence() {
        XCTAssertEqual(
            DeterministicTranscriptCleanup.finalize(
                "  please send the report to Jasen Guerra  "
            ),
            "Please send the report to Jasen Guerra."
        )
    }

    func testDeterministicFinalizerPreservesExistingPunctuation() {
        XCTAssertEqual(
            DeterministicTranscriptCleanup.finalize("Is port 443 open?"),
            "Is port 443 open?"
        )
        XCTAssertEqual(
            DeterministicTranscriptCleanup.finalize("Deployment complete."),
            "Deployment complete."
        )
    }

    func testDeterministicFinalizerPreservesEmptyInput() {
        XCTAssertEqual(
            DeterministicTranscriptCleanup.finalize(" \n "),
            ""
        )
    }

    func testProductionModelManifestIsRevisionAndHashPinned() {
        let manifest = LocalCleanupModelManifest.production

        XCTAssertEqual(
            manifest.revision,
            "7dabda4d13d513e3e842b20f0d435c732f172cbe"
        )
        XCTAssertEqual(manifest.sha256.count, 64)
        XCTAssertEqual(manifest.byteCount, 2_104_932_768)
        XCTAssertEqual(manifest.license, "Apache-2.0")
        XCTAssertEqual(
            manifest.downloadURL.absoluteString,
            "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/"
                + "7dabda4d13d513e3e842b20f0d435c732f172cbe/"
                + "qwen2.5-3b-instruct-q4_k_m.gguf"
        )
    }

    func testCleanupDeadlinesAndOutputLimitFollowMeasuredPolicy() {
        XCTAssertEqual(
            LocalCleanupRuntimeConfiguration.requestDeadline(wordCount: 40),
            .seconds(1.5)
        )
        XCTAssertEqual(
            LocalCleanupRuntimeConfiguration.requestDeadline(wordCount: 100),
            .seconds(2.5)
        )
        XCTAssertEqual(
            LocalCleanupRuntimeConfiguration.maximumOutputTokens(
                estimatedInputTokens: 100
            ),
            144
        )
    }

    func testTranscriptProtectorRestoresDictionaryAndFragileValues() throws {
        let input = """
        email Jasen.Guerra@example.com about Azure VM v2.4.1 at 10:30 AM on \
        2026-07-30 from 10.0.0.8 using --dry-run
        """
        let protected = TranscriptProtector.protect(
            input,
            dictionary: ["Jasen Guerra", "Azure VM"]
        )

        XCTAssertFalse(protected.replacements.isEmpty)
        XCTAssertEqual(try protected.restore(protected.text), input)
    }

    func testTranscriptProtectorRejectsRemovedPlaceholder() {
        let protected = TranscriptProtector.protect(
            "Send this to Jasen Guerra.",
            dictionary: ["Jasen Guerra"]
        )
        XCTAssertThrowsError(
            try protected.restore(
                protected.text.replacingOccurrences(
                    of: "[[PROTECTED_0001]]",
                    with: "Jason Guerra"
                )
            )
        )
    }

    func testTranscriptProtectorRejectsUnknownOrDuplicatedPlaceholder() {
        let protected = TranscriptProtector.protect(
            "Email me at test@example.com.",
            dictionary: []
        )
        XCTAssertThrowsError(
            try protected.restore(
                protected.text + " [[PROTECTED_9999]]"
            )
        )
        XCTAssertThrowsError(
            try protected.restore(
                protected.text + " [[PROTECTED_0001]]"
            )
        )
    }

    func testLocalCleanupEngineRestoresProtectedTermsAndFinalizes() async throws {
        let transport = FakeLocalCleanupTransport(
            response: "send it to [[PROTECTED_0001]] tomorrow"
        )
        let engine = LocalCleanupEngine(transport: transport)

        let result = try await engine.correct(
            text: "send it to Jasen Guerra tomorrow",
            dictionary: ["Jasen Guerra"]
        )

        XCTAssertEqual(result, "Send it to Jasen Guerra tomorrow.")
        let counts = await transport.counts
        XCTAssertEqual(counts.ensureReady, 1)
        XCTAssertEqual(counts.complete, 1)
        XCTAssertEqual(counts.recycle, 0)
        await engine.shutdown()
    }

    func testLocalCleanupEngineTimeoutRecyclesTransport() async {
        let transport = FakeLocalCleanupTransport(
            response: "Never returned.",
            completionDelay: .seconds(1)
        )
        let engine = LocalCleanupEngine(
            transport: transport,
            deadline: { _ in .milliseconds(20) }
        )

        do {
            _ = try await engine.correct(text: "hello there", dictionary: [])
            XCTFail("Expected cleanup to time out")
        } catch WhisprLocalError.cleanupTimedOut {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let recycleCount = await transport.counts.recycle
        XCTAssertEqual(recycleCount, 1)
    }

    func testLocalCleanupEngineInvalidOutputRecyclesTransport() async {
        let transport = FakeLocalCleanupTransport(
            response: "Here is the cleaned transcript: Hello."
        )
        let engine = LocalCleanupEngine(transport: transport)

        await XCTAssertThrowsErrorAsync {
            _ = try await engine.correct(text: "hello", dictionary: [])
        }

        let recycleCount = await transport.counts.recycle
        XCTAssertEqual(recycleCount, 1)
    }

    func testBundledHelperCleansWithPinnedModelWhenFixtureIsAvailable() async throws {
        let modelURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appending(path: "WhisprLocal/BenchmarkModels")
        .appending(path: LocalCleanupModelManifest.production.filename)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("Pinned cleanup model is not available on this Mac.")
        }
        guard let executableURL = Bundle.main.resourceURL?
            .appending(path: "LocalCleanupRuntime")
            .appending(path: "llama-server"),
              FileManager.default.isExecutableFile(atPath: executableURL.path)
        else {
            throw XCTSkip("Bundled llama.cpp helper is not available.")
        }

        let transport = LlamaServerController(
            executableURL: executableURL,
            modelURL: modelURL
        )
        let engine = LocalCleanupEngine(
            transport: transport,
            deadline: { _ in .seconds(5) }
        )
        defer {
            Task { await engine.shutdown() }
        }

        await engine.prewarm()
        let result = try await engine.correct(
            text: "um i think we should we should restart the Azure VM tomorrow",
            dictionary: ["Azure VM"]
        )

        XCTAssertTrue(result.contains("Azure VM"))
        XCTAssertFalse(result.lowercased().contains("um "))
        XCTAssertFalse(result.contains("should we should"))
        await engine.shutdown()
    }

    func testCleanupModelManagerClonesAndVerifiesPinnedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WhisprLocalCleanupModelTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let modelData = Data("tiny model fixture".utf8)
        let source = root.appending(path: "source.gguf")
        try modelData.write(to: source)
        let sha256 = SHA256.hash(data: modelData)
            .map { String(format: "%02x", $0) }
            .joined()
        let manifest = LocalCleanupModelManifest(
            displayName: "Fixture",
            repository: "example/fixture",
            revision: "revision",
            filename: "fixture.gguf",
            sha256: sha256,
            byteCount: Int64(modelData.count),
            license: "Test"
        )
        let manager = LocalCleanupModelManager(
            baseDirectory: root.appending(path: "installed"),
            manifest: manifest,
            developmentCacheURL: source
        )

        let initialStatus = await manager.status()
        XCTAssertFalse(initialStatus.isReady)
        let prepared = try await manager.prepareFromExistingCache()
        XCTAssertTrue(prepared)
        let installedStatus = await manager.status()
        XCTAssertTrue(installedStatus.isReady)
        let installedURL = await manager.modelURL
        let installedData = try Data(contentsOf: installedURL)
        XCTAssertEqual(installedData, modelData)
    }
}

private actor FakeLocalCleanupTransport: LocalCleanupTransport {
    private(set) var ensureReadyCount = 0
    private(set) var completeCount = 0
    private(set) var recycleCount = 0
    private(set) var shutdownCount = 0

    private let response: String
    private let completionDelay: Duration?

    var counts: (ensureReady: Int, complete: Int, recycle: Int, shutdown: Int) {
        (ensureReadyCount, completeCount, recycleCount, shutdownCount)
    }

    init(response: String, completionDelay: Duration? = nil) {
        self.response = response
        self.completionDelay = completionDelay
    }

    func ensureReady() {
        ensureReadyCount += 1
    }

    func complete(_ request: LocalCleanupRequest) async throws -> LocalCleanupResponse {
        completeCount += 1
        if let completionDelay {
            try await Task.sleep(for: completionDelay)
        }
        return LocalCleanupResponse(text: response, cachedPromptTokens: nil)
    }

    func recycle() {
        recycleCount += 1
    }

    func shutdown() {
        shutdownCount += 1
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected expression to throw", file: file, line: line)
        } catch {
            // Expected.
        }
    }
}
