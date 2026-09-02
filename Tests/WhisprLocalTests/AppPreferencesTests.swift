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

    func testPreviousClipboardRestorationDefaultsOnAndPersists() {
        let suiteName = "WhisprLocalTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.restorePreviousClipboardAfterPaste)

        preferences.restorePreviousClipboardAfterPaste = false
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.restorePreviousClipboardAfterPaste)
    }

    func testLegacyClipboardPreferenceMigratesWithoutChangingBehavior() {
        let keepSuiteName = "WhisprLocalTests.\(UUID())"
        let keepDefaults = UserDefaults(suiteName: keepSuiteName)!
        defer { keepDefaults.removePersistentDomain(forName: keepSuiteName) }
        keepDefaults.set(true, forKey: "keepLastDictationOnClipboard")

        let keepPreferences = AppPreferences(defaults: keepDefaults)
        XCTAssertFalse(keepPreferences.restorePreviousClipboardAfterPaste)
        XCTAssertNil(
            keepDefaults.object(forKey: "keepLastDictationOnClipboard")
        )

        let restoreSuiteName = "WhisprLocalTests.\(UUID())"
        let restoreDefaults = UserDefaults(suiteName: restoreSuiteName)!
        defer {
            restoreDefaults.removePersistentDomain(forName: restoreSuiteName)
        }
        restoreDefaults.set(false, forKey: "keepLastDictationOnClipboard")

        let restorePreferences = AppPreferences(defaults: restoreDefaults)
        XCTAssertTrue(restorePreferences.restorePreviousClipboardAfterPaste)
        XCTAssertNil(
            restoreDefaults.object(forKey: "keepLastDictationOnClipboard")
        )
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

    func testLearningFromCorrectionsDefaultsOnAndPersists() {
        let suiteName = "WhisprLocalTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.learnFromCorrections)

        preferences.learnFromCorrections = false
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.learnFromCorrections)
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

    func testLearningNoticeUsesSameNonactivatingOverlayController() async throws {
        let controller = OverlayPanelController(
            learningNoticeDuration: .milliseconds(20)
        )
        let identity = controller.contentControllerIdentity
        let event = DictionaryLearningEvent(corrections: [
            CorrectionCandidate(original: "Jason", replacement: "Jasen")
        ])

        controller.showLearningNotice(event, position: .bottomCenter)

        XCTAssertEqual(controller.contentControllerIdentity, identity)
        XCTAssertEqual(controller.displayedLearningEvent, event)
        controller.update(for: .listening, position: .bottomCenter)
        XCTAssertNil(controller.displayedLearningEvent)
        XCTAssertEqual(controller.displayedState, .listening)
        XCTAssertEqual(controller.queuedLearningEventCount, 1)
        controller.update(for: .idle, position: .bottomCenter)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(controller.displayedLearningEvent)
    }

    func testLearningNoticeWaitsForIdleAndDismisses() async throws {
        let controller = OverlayPanelController(
            learningNoticeDuration: .milliseconds(30)
        )
        let event = DictionaryLearningEvent(corrections: [
            CorrectionCandidate(original: "croc", replacement: "grok")
        ])

        controller.update(for: .transcribing, position: .bottomCenter)
        controller.showLearningNotice(event, position: .bottomCenter)
        XCTAssertNil(controller.displayedLearningEvent)
        XCTAssertEqual(controller.queuedLearningEventCount, 1)

        controller.update(for: .idle, position: .bottomCenter)
        XCTAssertEqual(controller.displayedLearningEvent, event)
        XCTAssertEqual(controller.queuedLearningEventCount, 0)

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(controller.displayedLearningEvent)
    }

    func testLearningBatchShowsEveryExactMappingInOrder() async throws {
        let controller = OverlayPanelController(
            learningNoticeDuration: .milliseconds(100)
        )
        let first = CorrectionCandidate(original: "Jason", replacement: "Jasen")
        let second = CorrectionCandidate(original: "croc", replacement: "grok")

        controller.showLearningNotice(
            DictionaryLearningEvent(corrections: [first, second]),
            position: .bottomCenter
        )

        XCTAssertEqual(controller.displayedLearningEvent?.corrections, [first])
        XCTAssertEqual(controller.queuedLearningEventCount, 1)
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertEqual(controller.displayedLearningEvent?.corrections, [second])
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(controller.displayedLearningEvent)
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

    func testLearningOverlayCornersRenderFullyTransparent() throws {
        let event = DictionaryLearningEvent(corrections: [
            CorrectionCandidate(original: "Jason", replacement: "Jasen")
        ])
        let view = NSHostingView(
            rootView: DictationOverlayView(learningEvent: event)
        )
        view.frame = NSRect(
            origin: .zero,
            size: DictationOverlayView.learningPillSize
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
            XCTAssertEqual(color.alphaComponent, 0, accuracy: 1.0 / 255.0)
        }
    }

}
