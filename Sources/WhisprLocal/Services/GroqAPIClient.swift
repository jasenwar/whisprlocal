import Foundation
import OSLog

private let groqAPILogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "Groq"
)

enum GroqAPIError: LocalizedError, Equatable, Sendable {
    case missingCredential
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: TimeInterval?, dailyLimit: Bool)
    case offline
    case timedOut
    case serverUnavailable
    case invalidResponse
    case emptyResponse
    case completionBudgetExhausted
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .missingCredential: "A Groq API key is required."
        case .unauthorized: "The Groq API key was not accepted."
        case .forbidden: "The selected Groq model is not available for this API key."
        case .rateLimited: "Groq usage is temporarily limited."
        case .offline: "Groq could not be reached because the Mac appears to be offline."
        case .timedOut: "Groq took too long to respond."
        case .serverUnavailable: "Groq is temporarily unavailable."
        case .invalidResponse: "Groq returned an invalid response."
        case .emptyResponse: "Groq returned no text."
        case .completionBudgetExhausted:
            "Groq used its response budget before producing the cleaned text."
        case .requestFailed: "The Groq request failed."
        }
    }
}

protocol GroqHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionGroqTransport: GroqHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GroqAPIError.invalidResponse
        }
        return (data, http)
    }
}

struct GroqAPIClient: Sendable {
    static let defaultBaseURL = URL(string: "https://api.groq.com/openai/v1")!

    private let apiKeyProvider: @Sendable () -> String?
    private let transport: any GroqHTTPTransport
    private let baseURL: URL

    init(
        apiKeyProvider: @escaping @Sendable () -> String?,
        transport: any GroqHTTPTransport = URLSessionGroqTransport(),
        baseURL: URL = GroqAPIClient.defaultBaseURL
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.transport = transport
        self.baseURL = baseURL
    }

    var hasCredential: Bool {
        guard let value = apiKeyProvider()?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) else { return false }
        return !value.isEmpty
    }

    func validateCredential() async throws {
        var request = try authorizedRequest(
            path: "models",
            method: "GET",
            timeout: 10
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, response) = try await perform(request)
        try validate(response: response, data: Data())
    }

    func transcribe(
        samples: [Float],
        sampleRate: Int,
        hotwords: [String],
        model: GroqTranscriptionModel
    ) async throws -> String {
        let started = ContinuousClock.now
        let audio = WAVEncoder.pcm16Mono(
            samples: samples,
            sampleRate: sampleRate
        )
        let boundary = "WhisprLocal-\(UUID().uuidString)"
        var request = try authorizedRequest(
            path: "audio/transcriptions",
            method: "POST",
            timeout: 20
        )
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = multipartTranscriptionBody(
            audio: audio,
            boundary: boundary,
            model: model.rawValue,
            hotwords: hotwords
        )

        let (data, response) = try await perform(request)
        try validate(response: response, data: data)
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let rawText = object["text"] as? String
        else {
            throw GroqAPIError.invalidResponse
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GroqAPIError.emptyResponse }
        groqAPILogger.info(
            "Groq transcription completed model=\(model.rawValue, privacy: .public) audioBytes=\(audio.count, privacy: .public) in \((ContinuousClock.now - started).timeInterval, format: .fixed(precision: 3), privacy: .public)s"
        )
        return text
    }

    func complete(
        systemPrompt: String,
        userText: String,
        imageJPEG: Data? = nil,
        model: String,
        maximumTokens: Int = 1_024,
        timeout: TimeInterval = 20
    ) async throws -> String {
        let started = ContinuousClock.now
        var request = try authorizedRequest(
            path: "chat/completions",
            method: "POST",
            timeout: timeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let userContent: Any
        if let imageJPEG {
            userContent = [
                ["type": "text", "text": userText],
                [
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())"
                    ],
                ],
            ]
        } else {
            userContent = userText
        }

        var payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_completion_tokens": maximumTokens,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
        ]
        switch model {
        case GroqCleanupModel.gptOSS20B.rawValue,
                GroqCleanupModel.gptOSS120B.rawValue:
            payload["reasoning_effort"] = "low"
            payload["include_reasoning"] = false
        case GroqCleanupModel.qwen36.rawValue:
            payload["reasoning_effort"] = "none"
            payload["include_reasoning"] = false
        default:
            break
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await perform(request)
        try validate(response: response, data: data)
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any]
        else {
            throw GroqAPIError.invalidResponse
        }
        let rawText = message["content"] as? String ?? ""
        let finishReason = first["finish_reason"] as? String ?? "unknown"
        let reasoningCharacters = (message["reasoning"] as? String)?.count
            ?? (message["reasoning_content"] as? String)?.count
            ?? 0
        let usage = object["usage"] as? [String: Any]
        let promptTokens = usage?["prompt_tokens"] as? Int ?? -1
        let completionTokens = usage?["completion_tokens"] as? Int ?? -1
        groqAPILogger.info(
            "Groq completion response model=\(model, privacy: .public) finish=\(finishReason, privacy: .public) budget=\(maximumTokens, privacy: .public) promptTokens=\(promptTokens, privacy: .public) completionTokens=\(completionTokens, privacy: .public) contentCharacters=\(rawText.count, privacy: .public) reasoningCharacters=\(reasoningCharacters, privacy: .public) imageAttached=\(imageJPEG != nil, privacy: .public) in \((ContinuousClock.now - started).timeInterval, format: .fixed(precision: 3), privacy: .public)s"
        )
        let text = Self.strippingReasoningTags(rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if finishReason == "length" {
                throw GroqAPIError.completionBudgetExhausted
            }
            throw GroqAPIError.emptyResponse
        }
        return text
    }

    private func authorizedRequest(
        path: String,
        method: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let apiKey = apiKeyProvider()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            throw GroqAPIError.missingCredential
        }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.data(for: request)
        } catch let error as GroqAPIError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost,
                    .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw GroqAPIError.offline
            case .timedOut:
                throw GroqAPIError.timedOut
            default:
                throw GroqAPIError.requestFailed
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GroqAPIError.requestFailed
        }
    }

    private func validate(response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw GroqAPIError.unauthorized
        case 403:
            throw GroqAPIError.forbidden
        case 429:
            let retryAfter = response.value(
                forHTTPHeaderField: "retry-after"
            ).flatMap(TimeInterval.init)
            let body = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            let isDaily = body.contains("daily")
                || body.contains("requests per day")
                || body.contains("tokens per day")
                || body.contains("audio seconds per day")
            throw GroqAPIError.rateLimited(
                retryAfter: retryAfter,
                dailyLimit: isDaily
            )
        case 408:
            throw GroqAPIError.timedOut
        case 498, 500...599:
            throw GroqAPIError.serverUnavailable
        default:
            throw GroqAPIError.requestFailed
        }
    }

    private func multipartTranscriptionBody(
        audio: Data,
        boundary: String,
        model: String,
        hotwords: [String]
    ) -> Data {
        var body = Data()
        func append(_ value: String) {
            body.append(Data(value.utf8))
        }

        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        field("model", model)
        field("response_format", "json")
        field("language", "en")
        field("temperature", "0")
        let terms = hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var selectedTerms: [String] = []
        var characterCount = 0
        for term in terms {
            let clipped = String(term.prefix(80))
            let addedCount = clipped.count + (selectedTerms.isEmpty ? 0 : 2)
            guard characterCount + addedCount <= 700 else { break }
            selectedTerms.append(clipped)
            characterCount += addedCount
        }
        let vocabulary = selectedTerms.joined(separator: ", ")
        if !vocabulary.isEmpty {
            field("prompt", "Preferred spellings: \(vocabulary)")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func strippingReasoningTags(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: "(?is)<think>.*?</think>"
        ) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: ""
        )
    }
}

enum WAVEncoder {
    static func pcm16Mono(samples: [Float], sampleRate: Int) -> Data {
        let sampleCount = samples.count
        let dataByteCount = sampleCount * MemoryLayout<Int16>.size
        var data = Data(capacity: 44 + dataByteCount)

        func appendASCII(_ value: String) {
            data.append(contentsOf: value.utf8)
        }

        func appendUInt16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        func appendUInt32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataByteCount))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))
        appendUInt16(2)
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(UInt32(dataByteCount))

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(
                (clamped * Float(Int16.max)).rounded()
            ).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }
}
