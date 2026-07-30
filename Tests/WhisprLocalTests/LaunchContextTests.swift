import AppKit
import CoreServices
import XCTest
@testable import WhisprLocal

@MainActor
final class LaunchContextTests: XCTestCase {
    func testAppDisablesSystemSessionRelaunch() {
        let relaunchController = LoginRelaunchControllerSpy()
        let delegate = AppDelegate(relaunchController: relaunchController)

        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )

        XCTAssertTrue(relaunchController.didDisableRelaunch)
    }

    func testLoginItemOpenEventIsRecognized() {
        let event = openApplicationEvent()
        event.setParam(
            NSAppleEventDescriptor(boolean: true),
            forKeyword: keyAELaunchedAsLogInItem
        )

        XCTAssertTrue(AppDelegate.isLoginItemLaunch(event))
    }

    func testOrdinaryOpenEventIsNotLoginLaunch() {
        XCTAssertFalse(AppDelegate.isLoginItemLaunch(openApplicationEvent()))
        XCTAssertFalse(AppDelegate.isLoginItemLaunch(nil))
    }

    func testSettingsWindowDoesNotParticipateInStateRestoration() {
        XCTAssertFalse(
            SettingsWindowController.shared.window?.isRestorable ?? true
        )
    }

    private func openApplicationEvent() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: kCoreEventClass,
            eventID: kAEOpenApplication,
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }
}

@MainActor
private final class LoginRelaunchControllerSpy: LoginRelaunchControlling {
    private(set) var didDisableRelaunch = false

    func disableRelaunchOnLogin() {
        didDisableRelaunch = true
    }
}
