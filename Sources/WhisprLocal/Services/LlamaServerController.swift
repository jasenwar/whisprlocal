import Darwin
import Foundation
import OSLog

private let localCleanupServerLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "LocalCleanupServer"
)

struct LocalCleanupRequest: Sendable {
    let systemPrompt: String
    let userPrompt: String
    let maximumOutputTokens: Int
}

struct LocalCleanupResponse: Sendable {
    let text: String
    let cachedPromptTokens: Int?
}

protocol LocalCleanupTransport: Sendable {
    func ensureReady() async throws -> UInt64
    func complete(_ request: LocalCleanupRequest) async throws -> LocalCleanupResponse
    func recycle() async
    func recycleAfterTimeout() async
    func shutdown() async
}

actor LlamaServerController: LocalCleanupTransport {
    private let executableURL: URL
    private let modelURL: URL
    private let logURL: URL
    private let session: URLSession
    private let startupTimeout: Duration

    private var process: Process?
    private var logHandle: FileHandle?
    private var port: UInt16?
    private var apiKey: String?
    private var processGeneration: UInt64 = 0

    init(
        executableURL: URL,
        modelURL: URL,
        logURL: URL? = nil,
        startupTimeout: Duration = .seconds(20),
        session: URLSession? = nil
    ) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.startupTimeout = startupTimeout
        self.session = session ?? Self.makeLoopbackSession()
        self.logURL = logURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(
            path: "WhisprLocal/Logs/local-cleanup-server.log"
        )
    }

    func ensureReady() async throws -> UInt64 {
        if let process, process.isRunning,
           let port, let apiKey,
           await healthIsReady(port: port, apiKey: apiKey) {
            return processGeneration
        }

        await stopOwnedProcess()
        try validateInputs()
        let selectedPort = try Self.availableLoopbackPort()
        let selectedAPIKey = UUID().uuidString
        try start(port: selectedPort, apiKey: selectedAPIKey)

        do {
            try await waitForHealth(port: selectedPort, apiKey: selectedAPIKey)
        } catch {
            await stopOwnedProcess()
            throw error
        }
        return processGeneration
    }

    func complete(_ request: LocalCleanupRequest) async throws -> LocalCleanupResponse {
        guard let process, process.isRunning, let port, let apiKey else {
            throw WhisprLocalError.cleanupRuntimeUnavailable
        }

        let endpoint = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                messages: [
                    .init(role: "system", content: request.systemPrompt),
                    .init(role: "user", content: request.userPrompt)
                ],
                temperature: 0,
                topP: 1,
                seed: 42,
                maximumTokens: request.maximumOutputTokens,
                stream: false,
                cachePrompt: true,
                slotID: LocalCleanupRuntimeConfiguration.promptCacheSlot,
                reasoningEffort: "none",
                enableThinking: false
            )
        )

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw LocalCleanupValidationError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content else {
            throw LocalCleanupValidationError.invalidResponse
        }
        return LocalCleanupResponse(
            text: text,
            cachedPromptTokens: decoded.usage?.promptTokensDetails?.cachedTokens
        )
    }

    func recycle() async {
        await stopOwnedProcess()
    }

    func recycleAfterTimeout() async {
        await stopOwnedProcess(gracePeriod: .milliseconds(150))
    }

    func shutdown() async {
        await stopOwnedProcess()
    }

    private func validateInputs() throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw WhisprLocalError.cleanupRuntimeUnavailable
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw WhisprLocalError.cleanupModelMissing
        }
    }

    private func start(port: UInt16, apiKey: String) throws {
        try LocalCleanupLogPolicy.prepareLogFile(at: logURL)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()

        let launched = Process()
        launched.executableURL = executableURL
        launched.currentDirectoryURL = executableURL.deletingLastPathComponent()
        launched.arguments = [
            "--model", modelURL.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", String(LocalCleanupRuntimeConfiguration.contextSize),
            "--parallel", "1",
            "--gpu-layers", "all",
            "--threads-http", "1",
            "--timeout", "10",
            "--no-webui",
            "--offline",
            "--api-key", apiKey,
            "--log-colors", "off",
            "--log-timestamps",
            "--verbosity", "1"
        ]
        launched.standardOutput = handle
        launched.standardError = handle
        launched.terminationHandler = { process in
            localCleanupServerLogger.info(
                "Owned helper exited with status \(process.terminationStatus, privacy: .public)"
            )
        }

        do {
            try launched.run()
        } catch {
            try? handle.close()
            throw WhisprLocalError.cleanupRuntimeUnavailable
        }

        self.process = launched
        processGeneration &+= 1
        logHandle = handle
        self.port = port
        self.apiKey = apiKey
        localCleanupServerLogger.info(
            "Started owned loopback helper pid=\(launched.processIdentifier, privacy: .public)"
        )
    }

    private func waitForHealth(port: UInt16, apiKey: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: startupTimeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if await healthIsReady(port: port, apiKey: apiKey) {
                return
            }
            if process?.isRunning != true {
                throw WhisprLocalError.cleanupRuntimeUnavailable
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        throw WhisprLocalError.cleanupTimedOut
    }

    private func healthIsReady(port: UInt16, apiKey: String) async -> Bool {
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/health")!
        )
        request.timeoutInterval = 0.25
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let health = try? JSONDecoder().decode(HealthResponse.self, from: data)
        else {
            return false
        }
        return health.status == "ok"
    }

    private func stopOwnedProcess(
        gracePeriod: Duration = .seconds(2)
    ) async {
        guard let owned = process else {
            clearProcessState()
            return
        }
        process = nil
        let pid = owned.processIdentifier
        if owned.isRunning {
            owned.terminate()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: gracePeriod)
            while owned.isRunning, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if owned.isRunning, pid > 1 {
                kill(pid, SIGKILL)
            }
        }
        clearProcessState()
        localCleanupServerLogger.info(
            "Stopped owned helper pid=\(pid, privacy: .public)"
        )
    }

    private func clearProcessState() {
        try? logHandle?.close()
        logHandle = nil
        port = nil
        apiKey = nil
    }

    private static func availableLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw WhisprLocalError.cleanupRuntimeUnavailable
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            throw WhisprLocalError.cleanupRuntimeUnavailable
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw WhisprLocalError.cleanupRuntimeUnavailable
        }
        return UInt16(bigEndian: boundAddress.sin_port)
    }

    private static func makeLoopbackSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

enum LocalCleanupLogPolicy {
    static let maximumBytes: Int64 = 1_048_576

    static func prepareLogFile(
        at logURL: URL,
        maximumBytes limit: Int64 = maximumBytes
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: logURL.path) {
            let attributes = try fileManager.attributesOfItem(
                atPath: logURL.path
            )
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if byteCount >= limit {
                let archiveURL = logURL
                    .deletingPathExtension()
                    .appendingPathExtension("previous.log")
                if fileManager.fileExists(atPath: archiveURL.path) {
                    try fileManager.removeItem(at: archiveURL)
                }
                try fileManager.moveItem(at: logURL, to: archiveURL)
            }
        }

        if !fileManager.fileExists(atPath: logURL.path) {
            guard fileManager.createFile(atPath: logURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }
}

private struct HealthResponse: Decodable {
    let status: String
}

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let messages: [Message]
    let temperature: Double
    let topP: Double
    let seed: Int
    let maximumTokens: Int
    let stream: Bool
    let cachePrompt: Bool
    let slotID: Int
    let reasoningEffort: String
    let enableThinking: Bool

    enum CodingKeys: String, CodingKey {
        case messages
        case temperature
        case topP = "top_p"
        case seed
        case maximumTokens = "max_tokens"
        case stream
        case cachePrompt = "cache_prompt"
        case slotID = "id_slot"
        case reasoningEffort = "reasoning_effort"
        case enableThinking = "enable_thinking"
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }

    struct Usage: Decodable {
        struct PromptTokenDetails: Decodable {
            let cachedTokens: Int?

            enum CodingKeys: String, CodingKey {
                case cachedTokens = "cached_tokens"
            }
        }

        let promptTokensDetails: PromptTokenDetails?

        enum CodingKeys: String, CodingKey {
            case promptTokensDetails = "prompt_tokens_details"
        }
    }

    let choices: [Choice]
    let usage: Usage?
}
