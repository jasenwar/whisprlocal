import Foundation
import SherpaRuntime

actor ParakeetTranscriptionEngine: TranscriptionEngine {
    private let modelManager: ModelManager
    private var recognizer: RecognizerHandle?
    private var hotwordEncoder: HotwordEncoder?
    private var lastUsed = Date.distantPast
    private var releaseTask: Task<Void, Never>?

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    func transcribe(
        samples: [Float],
        sampleRate: Int,
        hotwords: [String]
    ) async throws -> Transcript {
        guard samples.count >= sampleRate / 5 else {
            throw WhisprLocalError.recordingTooShort
        }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        guard rms > 0.0008 else { throw WhisprLocalError.noSpeech }

        try await ensureRecognizer()
        guard let recognizer = recognizer?.pointer else {
            throw WhisprLocalError.transcriptionFailed
        }
        releaseTask?.cancel()
        lastUsed = Date()
        let started = ContinuousClock.now

        let normalizedHotwords = hotwordEncoder?.encode(hotwords) ?? ""

        let stream: OpaquePointer? = normalizedHotwords.withCString { pointer in
            normalizedHotwords.isEmpty
                ? SherpaOnnxCreateOfflineStream(recognizer)
                : SherpaOnnxCreateOfflineStreamWithHotwords(recognizer, pointer)
        }
        guard let stream else { throw WhisprLocalError.transcriptionFailed }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(
                stream,
                Int32(sampleRate),
                buffer.baseAddress,
                Int32(clamping: samples.count)
            )
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            throw WhisprLocalError.transcriptionFailed
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        guard let textPointer = result.pointee.text else {
            throw WhisprLocalError.noSpeech
        }
        let text = String(cString: textPointer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WhisprLocalError.noSpeech }

        scheduleRelease()
        let duration = ContinuousClock.now - started
        return Transcript(
            text: text,
            engine: "sherpa-onnx \(sherpaOnnxPinnedVersion) / Parakeet Unified English",
            duration: duration.timeInterval
        )
    }

    func prewarm() async {
        try? await ensureRecognizer()
    }

    func releaseIfIdle() {
        guard Date().timeIntervalSince(lastUsed) >= 600 else { return }
        recognizer = nil
    }

    private func ensureRecognizer() async throws {
        guard recognizer == nil else { return }
        let paths = try await modelManager.paths()
        recognizer = try createRecognizer(paths: paths).map(RecognizerHandle.init)
        hotwordEncoder = try HotwordEncoder(tokensFile: paths.tokens)
        guard recognizer != nil else { throw WhisprLocalError.transcriptionFailed }
    }

    private func createRecognizer(paths: ParakeetModelPaths) throws -> OpaquePointer? {
        let strings = CStringStorage([
            paths.encoder,
            paths.decoder,
            paths.joiner,
            paths.tokens,
            "cpu",
            "nemo_transducer",
            "modified_beam_search",
            ""
        ])
        guard strings.count == 8 else { throw WhisprLocalError.transcriptionFailed }

        var configuration = SherpaOnnxOfflineRecognizerConfig()
        configuration.feat_config.sample_rate = 16_000
        configuration.feat_config.feature_dim = 80
        configuration.model_config.transducer.encoder = strings[0]
        configuration.model_config.transducer.decoder = strings[1]
        configuration.model_config.transducer.joiner = strings[2]
        configuration.model_config.tokens = strings[3]
        configuration.model_config.num_threads = 4
        configuration.model_config.debug = 0
        configuration.model_config.provider = strings[4]
        configuration.model_config.model_type = strings[5]
        configuration.decoding_method = strings[6]
        configuration.max_active_paths = 4
        configuration.hotwords_file = strings[7]
        configuration.hotwords_score = 1.5
        configuration.blank_penalty = 0
        return SherpaOnnxCreateOfflineRecognizer(&configuration)
    }

    private func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            await self?.releaseIfIdle()
        }
    }
}

private final class CStringStorage {
    private var pointers: [UnsafeMutablePointer<CChar>] = []

    init(_ values: [String]) {
        pointers = values.compactMap { strdup($0) }
    }

    deinit {
        pointers.forEach { pointer in
            free(UnsafeMutableRawPointer(pointer))
        }
    }

    var count: Int { pointers.count }

    subscript(index: Int) -> UnsafePointer<CChar> {
        UnsafePointer(pointers[index])
    }
}

private final class RecognizerHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(pointer)
    }
}
