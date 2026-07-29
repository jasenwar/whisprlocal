import AppKit
import Foundation
import XCTest
@testable import WhisprLocal

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testMenuBarPreferenceDefaultsOffAndPersists() {
        let suiteName = "WhisprLocalTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.showMenuBarIcon)

        preferences.showMenuBarIcon = true
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.showMenuBarIcon)
    }

    func testOverlayPositionDefaultsToTopCenterAndPersists() {
        let suiteName = "WhisprLocalTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.overlayPosition, .topCenter)

        preferences.overlayPosition = .bottomCenter
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.overlayPosition, .bottomCenter)
    }

    func testBottomCenterOverlayOriginUsesVisibleFrame() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1_200, height: 800)
        let size = NSSize(width: 240, height: 64)

        let origin = OverlayPosition.bottomCenter.origin(
            for: size,
            in: visibleFrame
        )

        XCTAssertEqual(origin.x, 580)
        XCTAssertEqual(origin.y, 92)
    }
}
