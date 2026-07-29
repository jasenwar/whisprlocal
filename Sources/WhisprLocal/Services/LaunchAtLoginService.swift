import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginService {
    static let helperIdentifier = "com.jasenguerra.whisprlocal.loginhelper"
    private let service = SMAppService.loginItem(identifier: helperIdentifier)

    var isEnabled: Bool {
        service.status == .enabled
    }

    var statusDescription: String {
        switch service.status {
        case .notRegistered: "Off"
        case .enabled: "On"
        case .requiresApproval: "Needs approval in Login Items"
        case .notFound: "Login helper not found"
        @unknown default: "Unknown"
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if service.status == .notRegistered {
                try service.register()
            }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    }
}
