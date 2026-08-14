import Foundation
import Security

final class GroqCredentialState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var revision = 0

    var apiKey: String? {
        lock.withLock { value }
    }

    var currentRevision: Int {
        lock.withLock { revision }
    }

    func set(_ apiKey: String?) {
        lock.withLock {
            value = Self.normalized(apiKey)
            revision += 1
        }
    }

    @discardableResult
    func setIfUnchanged(_ apiKey: String?, since expectedRevision: Int) -> Bool {
        lock.withLock {
            guard revision == expectedRevision else { return false }
            value = Self.normalized(apiKey)
            return true
        }
    }

    private static func normalized(_ apiKey: String?) -> String? {
        guard let trimmed = apiKey?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

final class GroqCredentialStore: @unchecked Sendable {
    private let service: String
    private let account = "groq-api-key"

    init(
        service: String = (Bundle.main.bundleIdentifier
            ?? BuildFlavor.productionBundleIdentifier) + ".credentials"
    ) {
        self.service = service
    }

    func apiKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func save(apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try remove()
            return
        }

        let data = Data(trimmed.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            update as CFDictionary
        )
        if status == errSecItemNotFound {
            var addition = baseQuery
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw GroqCredentialError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw GroqCredentialError.keychain(status)
        }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GroqCredentialError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum GroqCredentialError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return detail.map { "Could not update the Groq API key: \($0)" }
                ?? "Could not update the Groq API key."
        }
    }
}
