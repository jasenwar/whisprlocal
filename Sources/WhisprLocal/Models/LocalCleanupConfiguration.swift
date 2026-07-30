import Foundation

struct LocalCleanupModelManifest: Equatable, Sendable {
    let displayName: String
    let repository: String
    let revision: String
    let filename: String
    let sha256: String
    let byteCount: Int64
    let license: String

    var downloadURL: URL {
        URL(
            string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)"
        )!
    }

    func installedURL(baseDirectory: URL) -> URL {
        baseDirectory
            .appending(path: "Cleanup", directoryHint: .isDirectory)
            .appending(path: filename)
    }

    static let production = LocalCleanupModelManifest(
        displayName: "Qwen2.5 3B Instruct Q4_K_M",
        repository: "Qwen/Qwen2.5-3B-Instruct-GGUF",
        revision: "7dabda4d13d513e3e842b20f0d435c732f172cbe",
        filename: "qwen2.5-3b-instruct-q4_k_m.gguf",
        sha256: "626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d",
        byteCount: 2_104_932_768,
        license: "Apache-2.0"
    )
}

enum LocalCleanupRuntimeConfiguration {
    static let verifiedLlamaVersion = "10180"
    static let verifiedLlamaCommit = "11b068d06"
    static let contextSize = 2_048
    static let promptCacheSlot = 0
    static let requestOverheadTokens = 96
    static let contextSafetyMarginTokens = 128

    static func requestDeadline(wordCount: Int) -> Duration {
        switch wordCount {
        case ...40:
            .seconds(1.5)
        case 41...150:
            .seconds(2.5)
        default:
            .seconds(4)
        }
    }

    static func maximumOutputTokens(estimatedInputTokens: Int) -> Int {
        min(768, max(24, Int(Double(estimatedInputTokens) * 1.2) + 24))
    }

    static func estimatedRequestTokens(
        systemPrompt: String,
        userPrompt: String
    ) -> Int {
        estimatedTokenCount(systemPrompt)
            + estimatedTokenCount(userPrompt)
            + requestOverheadTokens
    }

    static func requestFitsContext(
        systemPrompt: String,
        userPrompt: String,
        maximumOutputTokens: Int
    ) -> Bool {
        estimatedRequestTokens(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )
            + maximumOutputTokens
            + contextSafetyMarginTokens
            <= contextSize
    }

    private static func estimatedTokenCount(_ text: String) -> Int {
        max(1, (text.utf8.count + 2) / 3)
    }
}
