@preconcurrency import AppKit
import Foundation

@MainActor
protocol PasteService: AnyObject {
    func paste(
        _ text: String,
        targetProcessIdentifier: pid_t?,
        restoringClipboard: Bool
    ) async throws
}

@MainActor
final class SystemPasteService: PasteService {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func paste(
        _ text: String,
        targetProcessIdentifier: pid_t?,
        restoringClipboard: Bool
    ) async throws {
        guard AXIsProcessTrusted() else {
            throw WhisprLocalError.accessibilityDenied
        }
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw WhisprLocalError.pasteFailed
        }

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: 9,
                keyDown: true
              ),
              let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: 9,
                keyDown: false
              )
        else {
            snapshot.restore(to: pasteboard)
            throw WhisprLocalError.pasteFailed
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        if let targetProcessIdentifier {
            down.postToPid(targetProcessIdentifier)
            up.postToPid(targetProcessIdentifier)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }

        if restoringClipboard {
            try? await Task.sleep(for: .milliseconds(350))
            snapshot.restore(to: pasteboard)
        }
    }
}

struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        PasteboardSnapshot(items: (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        })
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            values.forEach { type, data in
                item.setData(data, forType: type)
            }
            return item
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }
}
