import AppKit
import XCTest
@testable import WhisprLocal

@MainActor
final class PasteboardTests: XCTestCase {
    func testCompleteClipboardSnapshotRestoresMultipleTypes() throws {
        let pasteboard = NSPasteboard(name: .init("WhisprLocalTests.\(UUID())"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        item.setData(Data([1, 2, 3]), forType: .init("com.example.binary"))
        pasteboard.writeObjects([item])

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("temporary", forType: .string)
        snapshot.restore(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertEqual(
            pasteboard.data(forType: .init("com.example.binary")),
            Data([1, 2, 3])
        )
    }
}
