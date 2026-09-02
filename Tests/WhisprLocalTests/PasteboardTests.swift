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

    func testPasteTemporarilyExposesDictationThenRestoresClipboard() async throws {
        let pasteboard = makePasteboard(containing: "original")
        var textVisibleWhenCommandVWasPosted: String?
        let service = SystemPasteService(
            pasteboard: pasteboard,
            restorationDelay: .milliseconds(25),
            accessibilityTrustCheck: { true },
            pasteCommand: { _ in
                textVisibleWhenCommandVWasPosted = pasteboard.string(
                    forType: .string
                )
            }
        )

        try await service.paste(
            "dictated text",
            targetProcessIdentifier: nil,
            restoringClipboard: true
        )

        XCTAssertEqual(textVisibleWhenCommandVWasPosted, "dictated text")
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated text")

        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testRestorationDoesNotOverwriteSomethingCopiedAfterPaste() async throws {
        let pasteboard = makePasteboard(containing: "original")
        let service = SystemPasteService(
            pasteboard: pasteboard,
            restorationDelay: .milliseconds(25),
            accessibilityTrustCheck: { true },
            pasteCommand: { _ in }
        )

        try await service.paste(
            "dictated text",
            targetProcessIdentifier: nil,
            restoringClipboard: true
        )
        pasteboard.clearContents()
        pasteboard.setString("new copy", forType: .string)

        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(pasteboard.string(forType: .string), "new copy")
    }

    func testDictationRemainsWhenClipboardRestorationIsDisabled() async throws {
        let pasteboard = makePasteboard(containing: "original")
        let service = SystemPasteService(
            pasteboard: pasteboard,
            restorationDelay: .milliseconds(10),
            accessibilityTrustCheck: { true },
            pasteCommand: { _ in }
        )

        try await service.paste(
            "dictated text",
            targetProcessIdentifier: nil,
            restoringClipboard: false
        )

        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated text")
    }

    private func makePasteboard(containing text: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("WhisprLocalTests.\(UUID())"))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard
    }
}
