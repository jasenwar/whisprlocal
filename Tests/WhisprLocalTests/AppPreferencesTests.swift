import AppKit
import Foundation
import SwiftUI
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

    func testIndicatorDefaultsToFloatingPillAndPersistsNotchChoice() {
        let suiteName = "WhisprLocalTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.indicatorStyle, .floatingPill)

        preferences.indicatorStyle = .notch
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.indicatorStyle, .notch)
    }

    func testHybridPreferencesDefaultToGroqPreferredAndPersistLocalMode() {
        let suiteName = "WhisprLocalTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.processingMode, .groqPreferred)
        XCTAssertEqual(preferences.contextAwarenessLevel, .focusedWindow)
        XCTAssertEqual(preferences.groqTranscriptionModel, .whisperLargeV3)
        XCTAssertEqual(preferences.groqCleanupModel, .gptOSS20B)

        preferences.processingMode = .fullyLocal
        preferences.contextAwarenessLevel = .off
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.processingMode, .fullyLocal)
        XCTAssertEqual(reloaded.contextAwarenessLevel, .off)
    }

    func testPauseMediaDefaultsOnAndPersists() {
        let suiteName = "WhisprLocalTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.pauseMediaDuringDictation)

        preferences.pauseMediaDuringDictation = false
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.pauseMediaDuringDictation)
    }

    func testMicrophoneModeDefaultsToSystemAndPersistsBuiltInChoice() {
        let suiteName = "WhisprLocalTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.microphoneMode, .systemDefault)

        preferences.microphoneMode = .builtIn
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.microphoneMode, .builtIn)
    }

    func testKeepLastDictationOnClipboardDefaultsOnAndPersists() {
        let suiteName = "WhisprLocalTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.keepLastDictationOnClipboard)

        preferences.keepLastDictationOnClipboard = false
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.keepLastDictationOnClipboard)
    }

    func testDictationSoundsDefaultOffAndPersist() {
        let suiteName = "WhisprLocalTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.sounds)

        preferences.sounds = true
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.sounds)
    }

    func testCleanupDefaultsOnAndCanBeDisabled() {
        let suiteName = "WhisprLocalTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.cleanupEnabled)

        preferences.cleanupEnabled = false
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.cleanupEnabled)
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

    func testNotchLayoutBridgesPhysicalNotchBeforeDropDown() {
        let layout = NotchOverlayLayout(
            width: 185,
            topInset: 33
        )

        XCTAssertEqual(layout.width, 185)
        XCTAssertEqual(layout.topInset, 33)
        XCTAssertEqual(layout.dropDownHeight, 38)
        XCTAssertEqual(layout.size, CGSize(width: 185, height: 71))
        XCTAssertEqual(
            DictationOverlayView.size(
                for: .notch,
                notchLayout: layout
            ),
            layout.size
        )
    }

    func testOverlayReusesOneHostingControllerAcrossStateChanges() {
        let controller = OverlayPanelController()
        let identity = controller.contentControllerIdentity
        let states: [DictationState] = [
            .preparing,
            .listening,
            .transcribing,
            .correcting,
            .pasting,
            .succeeded,
        ]

        for state in states {
            controller.update(for: state, position: .bottomCenter)
            XCTAssertEqual(controller.contentControllerIdentity, identity)
            XCTAssertEqual(controller.displayedState, state)
        }
        controller.update(for: .idle, position: .bottomCenter)
    }

    func testOverlayCornersRenderFullyTransparent() throws {
        let view = NSHostingView(
            rootView: DictationOverlayView(state: .listening)
        )
        view.frame = NSRect(
            origin: .zero,
            size: DictationOverlayView.contentSize
        )
        view.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds)
        )
        view.cacheDisplay(in: view.bounds, to: representation)

        let inset = 8
        let samplePoints = [
            NSPoint(x: inset, y: inset),
            NSPoint(x: representation.pixelsWide - 1 - inset, y: inset),
            NSPoint(x: inset, y: representation.pixelsHigh - 1 - inset),
            NSPoint(
                x: representation.pixelsWide - 1 - inset,
                y: representation.pixelsHigh - 1 - inset
            ),
        ]

        for point in samplePoints {
            let color = try XCTUnwrap(
                representation.colorAt(
                    x: Int(point.x),
                    y: Int(point.y)
                )
            )
            XCTAssertEqual(
                color.alphaComponent,
                0,
                accuracy: 1.0 / 255.0,
                "Overlay corner at \(point) must remain transparent."
            )
        }
    }
}
