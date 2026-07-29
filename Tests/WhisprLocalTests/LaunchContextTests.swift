import AppKit
import CoreServices
import XCTest
@testable import WhisprLocal

@MainActor
final class LaunchContextTests: XCTestCase {
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
