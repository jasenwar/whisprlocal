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
}
