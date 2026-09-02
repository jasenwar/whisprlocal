@preconcurrency import AppKit
import Foundation
import OSLog

private let pasteboardLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "Pasteboard"
)

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
    typealias AccessibilityTrustCheck = @MainActor () -> Bool
    typealias PasteCommand = @MainActor (pid_t?) throws -> Void

    private struct PendingRestoration {
        let identifier: String
        let pastedText: String
        let snapshot: PasteboardSnapshot
    }

    private static let transientPasteboardType = NSPasteboard.PasteboardType(
        "com.jasenguerra.whisprlocal.transient-paste"
    )

    private let pasteboard: NSPasteboard
    private let restorationDelay: Duration
    private let accessibilityTrustCheck: AccessibilityTrustCheck
    private let pasteCommand: PasteCommand
    private var restorationTask: Task<Void, Never>?
    private var pendingRestoration: PendingRestoration?

    init(
        pasteboard: NSPasteboard = .general,
        restorationDelay: Duration = .milliseconds(500),
        accessibilityTrustCheck: @escaping AccessibilityTrustCheck = {
            AXIsProcessTrusted()
        },
        pasteCommand: PasteCommand? = nil
    ) {
        self.pasteboard = pasteboard
        self.restorationDelay = restorationDelay
        self.accessibilityTrustCheck = accessibilityTrustCheck
        self.pasteCommand = pasteCommand ?? { processIdentifier in
            try SystemPasteService.postCommandV(
                targetProcessIdentifier: processIdentifier
            )
        }
    }

    func paste(
        _ text: String,
        targetProcessIdentifier: pid_t?,
        restoringClipboard: Bool
    ) async throws {
        guard accessibilityTrustCheck() else {
            throw WhisprLocalError.accessibilityDenied
        }

        // A second paste should never snapshot WhisprLocal's temporary value.
        // Finish an outstanding restoration first if a new request arrives
        // during the short handoff window.
        finishPendingRestoration()

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let pasteIdentifier = UUID().uuidString
        pasteboard.clearContents()

        let wroteText: Bool
        if restoringClipboard {
            let item = NSPasteboardItem()
            wroteText = item.setString(text, forType: .string)
                && item.setString(
                    pasteIdentifier,
                    forType: Self.transientPasteboardType
                )
                && pasteboard.writeObjects([item])
        } else {
            wroteText = pasteboard.setString(text, forType: .string)
        }

        guard wroteText else {
            snapshot.restore(to: pasteboard)
            throw WhisprLocalError.pasteFailed
        }

        do {
            try pasteCommand(targetProcessIdentifier)
        } catch {
            snapshot.restore(to: pasteboard)
            throw error
        }

        guard restoringClipboard else {
            pasteboardLogger.info(
                "Paste completed; dictated text remains on clipboard by preference"
            )
            return
        }

        scheduleRestoration(
            PendingRestoration(
                identifier: pasteIdentifier,
                pastedText: text,
                snapshot: snapshot
            )
        )
    }

    private static func postCommandV(
        targetProcessIdentifier: pid_t?
    ) throws {
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
    }

    private func scheduleRestoration(_ restoration: PendingRestoration) {
        pendingRestoration = restoration
        restorationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: restorationDelay)
            } catch {
                return
            }
            restorePendingClipboard(identifier: restoration.identifier)
        }
        pasteboardLogger.info(
            "Paste completed; previous clipboard restoration scheduled"
        )
    }

    private func finishPendingRestoration() {
        restorationTask?.cancel()
        restorationTask = nil
        guard let restoration = pendingRestoration else { return }
        pendingRestoration = nil
        restoreClipboardIfStillTemporary(restoration)
    }

    private func restorePendingClipboard(identifier: String) {
        guard let restoration = pendingRestoration,
              restoration.identifier == identifier else {
            return
        }
        restorationTask = nil
        pendingRestoration = nil
        restoreClipboardIfStillTemporary(restoration)
    }

    private func restoreClipboardIfStillTemporary(
        _ restoration: PendingRestoration
    ) {
        let markerMatches = pasteboard.string(
            forType: Self.transientPasteboardType
        ) == restoration.identifier
        let textStillMatches = pasteboard.string(forType: .string)
            == restoration.pastedText

        guard markerMatches || textStillMatches else {
            // Never destroy something the user copied during the handoff.
            pasteboardLogger.notice(
                "Previous clipboard restoration skipped because the clipboard changed after paste"
            )
            return
        }

        if restoration.snapshot.restore(to: pasteboard) {
            pasteboardLogger.info("Previous clipboard restored after paste")
        } else if restoration.snapshot.restore(to: pasteboard) {
            pasteboardLogger.notice(
                "Previous clipboard restored after one pasteboard retry"
            )
        } else {
            pasteboardLogger.error(
                "Previous clipboard restoration failed after retry"
            )
        }
    }
}

struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        PasteboardSnapshot(items: (pasteboard.pasteboardItems ?? []).compactMap { item in
            let values = Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
            return values.isEmpty ? nil : values
        })
    }

    @discardableResult
    func restore(to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            values.forEach { type, data in
                item.setData(data, forType: type)
            }
            return item
        }
        guard !restored.isEmpty else {
            return true
        }
        return pasteboard.writeObjects(restored)
    }
}
