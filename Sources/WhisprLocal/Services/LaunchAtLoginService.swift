import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginService {
    private let service: SMAppService
    private(set) var status: SMAppService.Status

    var isEnabled: Bool {
        status == .enabled
    }

    var statusDescription: String {
        switch status {
        case .notRegistered: "Off"
        case .enabled: "On"
        case .requiresApproval: "Needs approval in System Settings → Login Items"
        case .notFound: "Off"
        @unknown default: "Unknown"
        }
    }

    init(service: SMAppService = .mainApp) {
        self.service = service
        status = service.status
    }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) throws {
        defer { refresh() }

        if enabled {
            switch service.status {
            case .enabled:
                return
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                try service.register()
            }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    }
}
