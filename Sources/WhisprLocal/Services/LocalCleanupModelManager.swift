import CryptoKit
import Darwin
import Foundation

enum LocalCleanupModelStatus: Equatable, Sendable {
    case missing
    case ready(URL)

    var isReady: Bool {
        if case .ready = self { true } else { false }
    }
}

actor LocalCleanupModelManager {
    let manifest: LocalCleanupModelManifest
    let modelURL: URL

    private let verificationURL: URL
    private let developmentCacheURL: URL

    init(
        baseDirectory: URL? = nil,
        manifest: LocalCleanupModelManifest = .production,
        developmentCacheURL: URL? = nil
    ) {
        let base = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "WhisprLocal/Models", directoryHint: .isDirectory)

        self.manifest = manifest
        modelURL = manifest.installedURL(baseDirectory: base)
        verificationURL = modelURL.appendingPathExtension("verified-sha256")
        self.developmentCacheURL = developmentCacheURL
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appending(path: "WhisprLocal/BenchmarkModels", directoryHint: .isDirectory)
            .appending(path: manifest.filename)
    }

    func status() -> LocalCleanupModelStatus {
        guard installedFileHasExpectedSize(),
              (try? String(contentsOf: verificationURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)) == manifest.sha256
        else {
            return .missing
        }
        return .ready(modelURL)
    }

    func prepareFromExistingCache() throws -> Bool {
        if status().isReady {
            return true
        }
        guard FileManager.default.fileExists(atPath: developmentCacheURL.path) else {
            return false
        }
        try installVerifiedFile(from: developmentCacheURL, preferClone: true)
        return true
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let (temporaryURL, response) = try await URLSession.shared.download(
            from: manifest.downloadURL
        )
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw WhisprLocalError.cleanupModelMissing
        }
        progress(0.9)
        try installVerifiedFile(from: temporaryURL, preferClone: false)
        progress(1)
    }

    private func installVerifiedFile(from source: URL, preferClone: Bool) throws {
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? 0) == manifest.byteCount else {
            throw LocalCleanupValidationError.invalidModel(
                "expected \(manifest.byteCount) bytes"
            )
        }
        guard try sha256(of: source) == manifest.sha256 else {
            throw LocalCleanupValidationError.invalidModel("SHA-256 mismatch")
        }

        let directory = modelURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let stagingURL = directory.appending(
            path: ".\(manifest.filename).\(UUID().uuidString).installing"
        )
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        if preferClone {
            let result = source.path.withCString { sourcePath in
                stagingURL.path.withCString { destinationPath in
                    copyfile(
                        sourcePath,
                        destinationPath,
                        nil,
                        copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)
                    )
                }
            }
            if result != 0 {
                try? FileManager.default.removeItem(at: stagingURL)
                try FileManager.default.copyItem(at: source, to: stagingURL)
            }
        } else {
            try FileManager.default.copyItem(at: source, to: stagingURL)
        }

        if FileManager.default.fileExists(atPath: modelURL.path) {
            try FileManager.default.removeItem(at: modelURL)
        }
        try FileManager.default.moveItem(at: stagingURL, to: modelURL)
        try (manifest.sha256 + "\n").write(
            to: verificationURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private func installedFileHasExpectedSize() -> Bool {
        guard let values = try? modelURL.resourceValues(forKeys: [.fileSizeKey]) else {
            return false
        }
        return Int64(values.fileSize ?? 0) == manifest.byteCount
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4_194_304), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
