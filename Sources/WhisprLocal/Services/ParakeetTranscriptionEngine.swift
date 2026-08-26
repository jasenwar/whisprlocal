import Foundation
import OSLog
import SherpaRuntime

private let transcriptionLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "Transcription"
)

actor ParakeetTranscriptionEngine: TranscriptionEngine {
    nonisolated static let requiredSampleRate = 16_000

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
        try await transcribe(
            samples: samples,
            sampleRate: sampleRate,
            hotwordPhrases: hotwords.map { HotwordPhrase($0) }
        )
    }

    func transcribe(
        samples: [Float],
        sampleRate: Int,
        hotwordPhrases: [HotwordPhrase]
    ) async throws -> Transcript {
        guard sampleRate == Self.requiredSampleRate else {
            transcriptionLogger.error(
                "Rejected transcription input with unsupported sample rate: actual=\(sampleRate, privacy: .public) required=\(Self.requiredSampleRate, privacy: .public)"
            )
            throw WhisprLocalError.transcriptionFailed
        }

        let metrics = AudioSignalMetrics(samples: samples)
        transcriptionLogger.info(
            "Transcription input: samples=\(samples.count, privacy: .public) duration=\(metrics.duration(sampleRate: Double(sampleRate)), format: .fixed(precision: 3), privacy: .public)s rms=\(metrics.rms, format: .fixed(precision: 6), privacy: .public) peak=\(metrics.peak, format: .fixed(precision: 6), privacy: .public)"
        )
        guard samples.count >= sampleRate / 5 else {
            transcriptionLogger.error(
                "Rejected recording as too short: samples=\(samples.count, privacy: .public)"
            )
            throw WhisprLocalError.recordingTooShort
        }
        guard metrics.rms > 0.0008 else {
            transcriptionLogger.error(
                "Rejected recording below speech threshold: rms=\(metrics.rms, format: .fixed(precision: 6), privacy: .public) threshold=0.000800"
            )
            throw WhisprLocalError.noSpeech
        }

        try await ensureRecognizer()
        guard let recognizer = recognizer?.pointer else {
            throw WhisprLocalError.transcriptionFailed
        }
        releaseTask?.cancel()
        lastUsed = Date()
        let started = ContinuousClock.now

        let hotwordEncoding = hotwordEncoder?.encode(hotwordPhrases)
            ?? HotwordEncodingResult(
                serialized: "",
                acceptedPhrases: [],
                droppedPhrases: hotwordPhrases
            )
        transcriptionLogger.info(
            "Hotword encoding completed: requested=\(hotwordPhrases.count, privacy: .public) accepted=\(hotwordEncoding.acceptedCount, privacy: .public) dropped=\(hotwordEncoding.droppedCount, privacy: .public)"
        )

        let preparedSamples = Self.addingBoundarySilence(
            to: samples,
            sampleRate: sampleRate,
            duration: 0.25
        )
        var text = try decode(
            recognizer: recognizer,
            samples: preparedSamples,
            sampleRate: sampleRate,
            hotwords: hotwordEncoding.serialized
        )

        if text.isEmpty {
            transcriptionLogger.info(
                "Primary decode was empty; retrying with additional boundary silence and no hotwords"
            )
            let retrySamples = Self.addingBoundarySilence(
                to: samples,
                sampleRate: sampleRate,
                duration: 0.60
            )
            text = try decode(
                recognizer: recognizer,
                samples: retrySamples,
                sampleRate: sampleRate,
                hotwords: ""
            )
        }

        guard !text.isEmpty else {
            transcriptionLogger.error(
                "Recognizer returned empty text after fallback decode despite audible input"
            )
            throw WhisprLocalError.noSpeech
        }

        scheduleRelease()
        let duration = ContinuousClock.now - started
        transcriptionLogger.info(
            "Transcription succeeded: characterCount=\(text.count, privacy: .public) processingSeconds=\(duration.timeInterval, format: .fixed(precision: 3), privacy: .public)"
        )
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

    nonisolated static func addingBoundarySilence(
        to samples: [Float],
        sampleRate: Int,
        duration: TimeInterval
    ) -> [Float] {
        guard sampleRate > 0, duration > 0 else { return samples }
        let silenceCount = Int((Double(sampleRate) * duration).rounded())
        guard silenceCount > 0 else { return samples }
        return Array(repeating: 0, count: silenceCount)
            + samples
            + Array(repeating: 0, count: silenceCount)
    }

    private func ensureRecognizer() async throws {
        guard recognizer == nil else { return }
        let paths = try await modelManager.paths()
        let createdHotwordEncoder = try HotwordEncoder(tokensFile: paths.tokens)
        guard let createdRecognizer = try createRecognizer(paths: paths) else {
            throw WhisprLocalError.transcriptionFailed
        }
        recognizer = RecognizerHandle(createdRecognizer)
        hotwordEncoder = createdHotwordEncoder
    }

    private func decode(
        recognizer: OpaquePointer,
        samples: [Float],
        sampleRate: Int,
        hotwords: String
    ) throws -> String {
        let stream: OpaquePointer? = hotwords.withCString { pointer in
            hotwords.isEmpty
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
            transcriptionLogger.error("Recognizer returned no result object")
            throw WhisprLocalError.transcriptionFailed
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        guard let textPointer = result.pointee.text else {
            transcriptionLogger.info(
                "Recognizer result had no text pointer"
            )
            return ""
        }
        return String(cString: textPointer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        configuration.feat_config.sample_rate = Int32(Self.requiredSampleRate)
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
