import CryptoKit
import Darwin
import Foundation

actor ModelManager {
    static let archiveURL = URL(string:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/" +
        "sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming.tar.bz2"
    )!
    static let archiveSHA256 = "99f63605b3a85a54c250c0869670a687b7d6598a47bf2421515e1f839a76e150"

    let modelDirectory: URL
    let existingCache = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".cache/openwhispr/parakeet-models/parakeet-unified-en-0.6b")

    init(baseDirectory: URL? = nil) {
        let base = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "WhisprLocal/Models", directoryHint: .isDirectory)
        modelDirectory = base.appending(
            path: "parakeet-unified-en-0.6b",
            directoryHint: .isDirectory
        )
    }

    func status() -> ModelStatus {
        do {
            try validate(directory: modelDirectory)
            return .ready(modelDirectory)
        } catch {
            return .missing
        }
    }

    func prepareFromExistingCache() throws -> Bool {
        guard !FileManager.default.fileExists(atPath: modelDirectory.path),
              FileManager.default.fileExists(atPath: existingCache.path)
        else { return status().isReady }

        try FileManager.default.createDirectory(
            at: modelDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try installRequiredFiles(from: existingCache, useClone: true)
        try validate(directory: modelDirectory)
        return true
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(
            at: modelDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let (temporaryURL, response) = try await URLSession.shared.download(from: Self.archiveURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WhisprLocalError.modelInvalid("download failed")
        }
        progress(0.8)
        let digest = try sha256(of: temporaryURL)
        guard digest == Self.archiveSHA256 else {
            throw WhisprLocalError.modelInvalid("SHA-256 mismatch")
        }

        let extractionRoot = FileManager.default.temporaryDirectory.appending(
            path: "WhisprLocal-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: extractionRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: extractionRoot) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", temporaryURL.path, "-C", extractionRoot.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WhisprLocalError.modelInvalid("archive extraction failed")
        }

        let extracted = extractionRoot.appending(
            path: "sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming",
            directoryHint: .isDirectory
        )
        try installRequiredFiles(from: extracted, useClone: false)
        try validate(directory: modelDirectory)
        progress(1)
    }

    func paths() throws -> ParakeetModelPaths {
        try validate(directory: modelDirectory)
        return ParakeetModelPaths(
            encoder: modelDirectory.appending(path: "encoder.int8.onnx").path,
            decoder: modelDirectory.appending(path: "decoder.int8.onnx").path,
            joiner: modelDirectory.appending(path: "joiner.int8.onnx").path,
            tokens: modelDirectory.appending(path: "tokens.txt").path
        )
    }

    private func validate(directory: URL) throws {
        for file in Self.requiredFiles {
            let url = directory.appending(path: file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw WhisprLocalError.modelInvalid("missing \(file)")
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) > 0 else {
                throw WhisprLocalError.modelInvalid("\(file) is empty")
            }
        }
    }

    private func installRequiredFiles(from source: URL, useClone: Bool) throws {
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        for file in Self.requiredFiles {
            let sourceFile = source.appending(path: file)
            let destinationFile = modelDirectory.appending(path: file)
            guard FileManager.default.fileExists(atPath: sourceFile.path) else {
                throw WhisprLocalError.modelInvalid("missing \(file)")
            }
            if useClone {
                let result = sourceFile.path.withCString { sourcePath in
                    destinationFile.path.withCString { destinationPath in
                        copyfile(
                            sourcePath,
                            destinationPath,
                            nil,
                            copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)
                        )
                    }
                }
                guard result == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } else {
                try FileManager.default.copyItem(at: sourceFile, to: destinationFile)
            }
        }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let requiredFiles = [
        "encoder.int8.onnx",
        "decoder.int8.onnx",
        "joiner.int8.onnx",
        "tokens.txt"
    ]
}

enum ModelStatus: Equatable, Sendable {
    case missing
    case ready(URL)

    var isReady: Bool {
        if case .ready = self { true } else { false }
    }
}

struct ParakeetModelPaths: Sendable {
    let encoder: String
    let decoder: String
    let joiner: String
    let tokens: String
}
