import Foundation
import XCTest
@testable import WhisprLocal

final class PostPasteCorrectionMonitorTests: XCTestCase {
    func testTracksCorrectionInsideMiddleOfDocument() throws {
        var tracker = try XCTUnwrap(PastedTextRangeTracker.start(
            document: "Before Jason after",
            pastedText: "Jason ",
            preferredLocation: 7
        ))

        XCTAssertEqual(
            tracker.update(document: "Before Jasen after"),
            .edited("Jasen ")
        )
        XCTAssertEqual(tracker.range, NSRange(location: 7, length: 6))
    }

    func testTypingAfterPasteDoesNotBecomeDictionaryInput() throws {
        var tracker = try XCTUnwrap(PastedTextRangeTracker.start(
            document: "Message: Jason ",
            pastedText: "Jason ",
            preferredLocation: 9
        ))

        XCTAssertEqual(
            tracker.update(document: "Message: Jason followed up"),
            .outsideEdit
        )
        XCTAssertEqual(
            tracker.update(document: "Message: Jasen followed up"),
            .edited("Jasen ")
        )
    }

    func testEditBeforePasteShiftsTrackedRange() throws {
        var tracker = try XCTUnwrap(PastedTextRangeTracker.start(
            document: "Hi Jason there",
            pastedText: "Jason ",
            preferredLocation: 3
        ))

        XCTAssertEqual(
            tracker.update(document: "Hello, Hi Jason there"),
            .outsideEdit
        )
        XCTAssertEqual(tracker.range.location, 10)
        XCTAssertEqual(
            tracker.update(document: "Hello, Hi Jasen there"),
            .edited("Jasen ")
        )
    }

    func testUnicodePrefixUsesAccessibilityUTF16Offsets() throws {
        let document = "👋🏽 Jason done"
        let location = ("👋🏽 " as NSString).length
        var tracker = try XCTUnwrap(PastedTextRangeTracker.start(
            document: document,
            pastedText: "Jason ",
            preferredLocation: location
        ))

        XCTAssertEqual(
            tracker.update(document: "👋🏽 Jasen done"),
            .edited("Jasen ")
        )
    }

    func testCrossBoundaryRewriteFailsClosed() throws {
        var tracker = try XCTUnwrap(PastedTextRangeTracker.start(
            document: "Before Jason after",
            pastedText: "Jason ",
            preferredLocation: 7
        ))

        XCTAssertEqual(
            tracker.update(document: "Before rewritten"),
            .invalid
        )
    }

    func testStartRequiresExactPastedTextAtCapturedSelection() {
        XCTAssertNil(PastedTextRangeTracker.start(
            document: "Before something else",
            pastedText: "Jason ",
            preferredLocation: 7
        ))
    }
}
