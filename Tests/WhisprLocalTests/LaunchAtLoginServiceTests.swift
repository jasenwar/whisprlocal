import ServiceManagement
import XCTest
@testable import WhisprLocal

@MainActor
final class LaunchAtLoginServiceTests: XCTestCase {
    func testMigratesEnabledLegacyRegistrationToHelper() {
        let helper = LoginItemServiceSpy(status: .notRegistered)
        let legacy = LoginItemServiceSpy(status: .enabled)
        let service = LaunchAtLoginService(
            service: helper,
            legacyService: legacy
        )

        service.migrateLegacyRegistrationIfNeeded()

        XCTAssertEqual(helper.registerCount, 1)
        XCTAssertEqual(helper.status, .enabled)
        XCTAssertEqual(legacy.unregisterCount, 1)
        XCTAssertEqual(legacy.status, .notRegistered)
        XCTAssertTrue(service.isEnabled)
    }

    func testMigrationKeepsLegacyRegistrationWhenHelperNeedsApproval() {
        let helper = LoginItemServiceSpy(
            status: .notRegistered,
            statusAfterRegister: .requiresApproval
        )
        let legacy = LoginItemServiceSpy(status: .enabled)
        let service = LaunchAtLoginService(
            service: helper,
            legacyService: legacy
        )

        service.migrateLegacyRegistrationIfNeeded()

        XCTAssertEqual(helper.registerCount, 1)
        XCTAssertEqual(helper.status, .requiresApproval)
        XCTAssertEqual(legacy.unregisterCount, 0)
        XCTAssertEqual(legacy.status, .enabled)
    }

    func testDisablingRemovesHelperAndLegacyRegistrations() throws {
        let helper = LoginItemServiceSpy(status: .enabled)
        let legacy = LoginItemServiceSpy(status: .enabled)
        let service = LaunchAtLoginService(
            service: helper,
            legacyService: legacy
        )

        try service.setEnabled(false)

        XCTAssertEqual(helper.unregisterCount, 1)
        XCTAssertEqual(legacy.unregisterCount, 1)
        XCTAssertFalse(service.isEnabled)
    }

    func testApprovalStatusOpensSystemSettings() throws {
        let helper = LoginItemServiceSpy(status: .requiresApproval)
        var didOpenSettings = false
        let service = LaunchAtLoginService(
            service: helper,
            legacyService: nil,
            openSystemSettings: {
                didOpenSettings = true
            }
        )

        try service.setEnabled(true)

        XCTAssertTrue(didOpenSettings)
        XCTAssertEqual(helper.registerCount, 0)
    }

    func testRepairReregistersEnabledHelperWhenAppLocationChanges() {
        let helper = LoginItemServiceSpy(status: .enabled)
        var storedFingerprint: String? = "old-path|26"
        let service = LaunchAtLoginService(
            service: helper,
            legacyService: nil,
            registrationFingerprint: "new-path|27",
            loadRegistrationFingerprint: { storedFingerprint },
            storeRegistrationFingerprint: { storedFingerprint = $0 }
        )

        service.repairRegistrationIfNeeded()

        XCTAssertEqual(helper.unregisterCount, 1)
        XCTAssertEqual(helper.registerCount, 1)
        XCTAssertEqual(storedFingerprint, "new-path|27")
        XCTAssertTrue(service.isEnabled)
    }

    func testRepairLeavesMatchingRegistrationAlone() {
        let helper = LoginItemServiceSpy(status: .enabled)
        let service = LaunchAtLoginService(
            service: helper,
            legacyService: nil,
            registrationFingerprint: "same-path|27",
            loadRegistrationFingerprint: { "same-path|27" }
        )

        service.repairRegistrationIfNeeded()

        XCTAssertEqual(helper.unregisterCount, 0)
        XCTAssertEqual(helper.registerCount, 0)
        XCTAssertTrue(service.isEnabled)
    }

    func testRepairPreservesMigrationErrorWhenHelperIsDisabled() {
        let helper = LoginItemServiceSpy(
            status: .notRegistered,
            registerError: LoginItemServiceSpyError.registrationFailed
        )
        let legacy = LoginItemServiceSpy(status: .enabled)
        let service = LaunchAtLoginService(
            service: helper,
            legacyService: legacy
        )

        service.migrateLegacyRegistrationIfNeeded()
        let migrationError = service.lastError
        service.repairRegistrationIfNeeded()

        XCTAssertNotNil(migrationError)
        XCTAssertEqual(service.lastError, migrationError)
    }
}

private enum LoginItemServiceSpyError: Error {
    case registrationFailed
}

@MainActor
private final class LoginItemServiceSpy: LoginItemServiceControlling {
    private(set) var status: SMAppService.Status
    private let statusAfterRegister: SMAppService.Status
    private let registerError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(
        status: SMAppService.Status,
        statusAfterRegister: SMAppService.Status = .enabled,
        registerError: Error? = nil
    ) {
        self.status = status
        self.statusAfterRegister = statusAfterRegister
        self.registerError = registerError
    }

    func register() throws {
        registerCount += 1
        if let registerError {
            throw registerError
        }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCount += 1
        status = .notRegistered
    }
}
