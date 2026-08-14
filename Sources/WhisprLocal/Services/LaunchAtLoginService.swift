import Foundation
import Observation
import ServiceManagement

@MainActor
protocol LoginItemServiceControlling: AnyObject {
    var status: SMAppService.Status { get }

    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemServiceControlling {}

@MainActor
@Observable
final class LaunchAtLoginService {
    static var helperBundleIdentifier: String {
        BuildFlavor.loginHelperBundleIdentifier
    }
    private static let registrationFingerprintKey =
        "loginItemRegistrationFingerprint"

    private let service: any LoginItemServiceControlling
    private let legacyService: (any LoginItemServiceControlling)?
    private let openSystemSettings: () -> Void
    private let registrationFingerprint: String
    private let loadRegistrationFingerprint: () -> String?
    private let storeRegistrationFingerprint: (String?) -> Void
    private(set) var status: SMAppService.Status
    private(set) var lastError: String?

    var isEnabled: Bool {
        status == .enabled
    }

    var statusDescription: String {
        if let lastError {
            return "Startup update failed: \(lastError)"
        }
        return switch status {
        case .notRegistered: "Off"
        case .enabled: "On"
        case .requiresApproval: "Needs approval in System Settings → Login Items"
        case .notFound: "Off"
        @unknown default: "Unknown"
        }
    }

    init(
        service: any LoginItemServiceControlling = SMAppService.loginItem(
            identifier: LaunchAtLoginService.helperBundleIdentifier
        ),
        legacyService: (any LoginItemServiceControlling)? = SMAppService.mainApp,
        openSystemSettings: @escaping () -> Void = {
            SMAppService.openSystemSettingsLoginItems()
        },
        registrationFingerprint: String =
            LaunchAtLoginService.currentRegistrationFingerprint,
        loadRegistrationFingerprint: @escaping () -> String? = {
            UserDefaults.standard.string(
                forKey: LaunchAtLoginService.registrationFingerprintKey
            )
        },
        storeRegistrationFingerprint: @escaping (String?) -> Void = { value in
            if let value {
                UserDefaults.standard.set(
                    value,
                    forKey: LaunchAtLoginService.registrationFingerprintKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: LaunchAtLoginService.registrationFingerprintKey
                )
            }
        }
    ) {
        self.service = service
        self.legacyService = legacyService
        self.openSystemSettings = openSystemSettings
        self.registrationFingerprint = registrationFingerprint
        self.loadRegistrationFingerprint = loadRegistrationFingerprint
        self.storeRegistrationFingerprint = storeRegistrationFingerprint
        status = service.status
    }

    func refresh() {
        status = service.status
    }

    func migrateLegacyRegistrationIfNeeded() {
        lastError = nil
        guard let legacyService, legacyService.status == .enabled else {
            refresh()
            return
        }

        do {
            if service.status != .enabled {
                guard service.status != .requiresApproval else {
                    refresh()
                    return
                }
                try service.register()
            }
            refresh()
            guard service.status == .enabled else { return }
            storeRegistrationFingerprint(registrationFingerprint)
            try legacyService.unregister()
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func repairRegistrationIfNeeded() {
        guard service.status == .enabled,
              loadRegistrationFingerprint() != registrationFingerprint else {
            refresh()
            return
        }

        lastError = nil
        do {
            try service.unregister()
            try service.register()
            refresh()
            if service.status == .enabled {
                storeRegistrationFingerprint(registrationFingerprint)
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func setEnabled(_ enabled: Bool) throws {
        lastError = nil
        defer { refresh() }

        if enabled {
            switch service.status {
            case .enabled:
                break
            case .requiresApproval:
                openSystemSettings()
                return
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                try service.register()
            }
            if service.status == .enabled {
                storeRegistrationFingerprint(registrationFingerprint)
                try unregisterLegacyIfNeeded()
            }
        } else {
            if service.status != .notRegistered,
               service.status != .notFound {
                try service.unregister()
            }
            try unregisterLegacyIfNeeded()
            storeRegistrationFingerprint(nil)
        }
    }

    private func unregisterLegacyIfNeeded() throws {
        guard let legacyService,
              legacyService.status != .notRegistered,
              legacyService.status != .notFound else {
            return
        }
        try legacyService.unregister()
    }

    private static var currentRegistrationFingerprint: String {
        let build = Bundle.main.object(
            forInfoDictionaryKey: kCFBundleVersionKey as String
        ) as? String ?? "unknown"
        return "\(Bundle.main.bundleURL.standardizedFileURL.path)|\(build)"
    }
}
