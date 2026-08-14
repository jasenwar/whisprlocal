import Foundation

enum GroqCapability: String, Codable, CaseIterable, Sendable {
    case transcription
    case cleanup
    case context
}

struct GroqRequestScope: Hashable, Codable, Sendable {
    let capability: GroqCapability
    let model: String

    static func transcription(_ model: GroqTranscriptionModel) -> Self {
        Self(capability: .transcription, model: model.rawValue)
    }

    static func cleanup(_ model: GroqCleanupModel) -> Self {
        Self(capability: .cleanup, model: model.rawValue)
    }

    static let context = Self(
        capability: .context,
        model: GroqContextModel.recommended
    )

    fileprivate var storageKey: String {
        "\(capability.rawValue)::\(model)"
    }
}

struct GroqAvailabilitySnapshot: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ready
        case missingCredential
        case temporarilyUnavailable
    }

    let state: State
    let message: String
    let retryAt: Date?

    static let missingCredential = GroqAvailabilitySnapshot(
        state: .missingCredential,
        message: "Add a Groq API key to enable cloud processing.",
        retryAt: nil
    )
}

actor GroqAvailabilityStore {
    private struct ScopedBlock: Codable, Equatable, Sendable {
        let retryAt: Date?
        let reason: String
    }

    private enum Key {
        static let scopedBlocks = "groqScopedBlocksV2"
        static let credentialBlock = "groqCredentialBlockV2"
        static let legacyBlockedUntil = "groqBlockedUntil"
        static let legacyBlockedReason = "groqBlockedReason"
    }

    private let defaults: UserDefaults
    private var scopedBlocks: [String: ScopedBlock]
    private var credentialBlock: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Key.scopedBlocks),
           let decoded = try? JSONDecoder().decode(
                [String: ScopedBlock].self,
                from: data
           ) {
            scopedBlocks = decoded
        } else {
            scopedBlocks = [:]
        }
        credentialBlock = defaults.string(forKey: Key.credentialBlock)

        // v1 treated one model or feature failure as a global outage. Starting
        // fresh is safer than carrying that overly broad cooldown forward.
        defaults.removeObject(forKey: Key.legacyBlockedUntil)
        defaults.removeObject(forKey: Key.legacyBlockedReason)
    }

    func mayAttempt(
        _ scope: GroqRequestScope,
        now: Date = Date()
    ) -> Bool {
        clearExpiredBlocks(now: now)
        return credentialBlock == nil
            && scopedBlocks[scope.storageKey] == nil
    }

    func recordSuccess(_ scope: GroqRequestScope) {
        credentialBlock = nil
        defaults.removeObject(forKey: Key.credentialBlock)
        guard scopedBlocks.removeValue(forKey: scope.storageKey) != nil else {
            return
        }
        persistScopedBlocks()
    }

    func recordFailure(
        _ error: GroqAPIError,
        scope: GroqRequestScope,
        now: Date = Date()
    ) {
        switch error {
        case .unauthorized:
            setCredentialBlock(
                "The Groq API key was rejected. Update it in Settings; local processing is active."
            )
            return
        case .missingCredential:
            setCredentialBlock(
                "No Groq API key is saved. Local processing is active."
            )
            return
        case .emptyResponse, .completionBudgetExhausted:
            return
        default:
            break
        }

        let block: ScopedBlock? = switch error {
        case .rateLimited(let retryAfter, let dailyLimit):
            if dailyLimit {
                ScopedBlock(
                    retryAt: retryAfter.map {
                        now.addingTimeInterval(max(5, $0))
                    } ?? Calendar.current.date(
                        byAdding: .day,
                        value: 1,
                        to: Calendar.current.startOfDay(for: now)
                    ),
                    reason: "This Groq model reached its daily usage limit. Only this processing path is using its local fallback."
                )
            } else {
                ScopedBlock(
                    retryAt: now.addingTimeInterval(
                        max(5, retryAfter ?? 60)
                    ),
                    reason: "This Groq model is temporarily rate-limited. Only this processing path is using its local fallback."
                )
            }
        case .offline:
            ScopedBlock(
                retryAt: now.addingTimeInterval(20),
                reason: "This Groq request could not connect. Its local fallback is active briefly."
            )
        case .timedOut:
            ScopedBlock(
                retryAt: now.addingTimeInterval(15),
                reason: "This Groq request timed out. Its local fallback is active briefly."
            )
        case .serverUnavailable:
            ScopedBlock(
                retryAt: now.addingTimeInterval(30),
                reason: "This Groq processing path is temporarily unavailable."
            )
        case .forbidden:
            ScopedBlock(
                retryAt: now.addingTimeInterval(300),
                reason: "This Groq model is not enabled for the current API key. Other Groq features remain available, and this model will be checked again later."
            )
        case .invalidResponse, .requestFailed:
            ScopedBlock(
                retryAt: now.addingTimeInterval(10),
                reason: "This Groq processing path returned an unusable response and is cooling down briefly."
            )
        case .missingCredential, .unauthorized, .emptyResponse,
                .completionBudgetExhausted:
            nil
        }

        guard let block else { return }
        scopedBlocks[scope.storageKey] = block
        persistScopedBlocks()
    }

    func recordConnectionSuccess() {
        credentialBlock = nil
        defaults.removeObject(forKey: Key.credentialBlock)
    }

    func recordConnectionFailure(_ error: GroqAPIError) {
        switch error {
        case .unauthorized, .missingCredential:
            recordFailure(
                error,
                scope: .context
            )
        case .forbidden:
            setCredentialBlock(
                "Groq access was denied for this API key. Update it in Settings; local processing is active."
            )
        default:
            break
        }
    }

    func credentialChanged() {
        credentialBlock = nil
        scopedBlocks.removeAll()
        defaults.removeObject(forKey: Key.credentialBlock)
        defaults.removeObject(forKey: Key.scopedBlocks)
    }

    func snapshot(
        hasCredential: Bool,
        now: Date = Date()
    ) -> GroqAvailabilitySnapshot {
        guard hasCredential else { return .missingCredential }
        clearExpiredBlocks(now: now)
        if let credentialBlock {
            return GroqAvailabilitySnapshot(
                state: .temporarilyUnavailable,
                message: credentialBlock,
                retryAt: nil
            )
        }
        guard !scopedBlocks.isEmpty else {
            return GroqAvailabilitySnapshot(
                state: .ready,
                message: "Groq is ready. Local fallback remains available.",
                retryAt: nil
            )
        }
        let retryAt = scopedBlocks.values.compactMap(\.retryAt).min()
        return GroqAvailabilitySnapshot(
            state: .temporarilyUnavailable,
            message: "One Groq processing path is using its local fallback; the other Groq features remain available.",
            retryAt: retryAt
        )
    }

    private func clearExpiredBlocks(now: Date) {
        let expiredKeys: [String] = scopedBlocks.compactMap { element in
            let (key, block) = element
            guard let retryAt = block.retryAt, retryAt <= now else {
                return nil
            }
            return key
        }
        guard !expiredKeys.isEmpty else { return }
        for key in expiredKeys {
            scopedBlocks.removeValue(forKey: key)
        }
        persistScopedBlocks()
    }

    private func setCredentialBlock(_ reason: String) {
        credentialBlock = reason
        defaults.set(reason, forKey: Key.credentialBlock)
    }

    private func persistScopedBlocks() {
        guard !scopedBlocks.isEmpty else {
            defaults.removeObject(forKey: Key.scopedBlocks)
            return
        }
        if let data = try? JSONEncoder().encode(scopedBlocks) {
            defaults.set(data, forKey: Key.scopedBlocks)
        }
    }
}
