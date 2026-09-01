@preconcurrency import AppKit
import ApplicationServices
import Foundation
import OSLog

private let correctionMonitorLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "CorrectionLearning"
)

/// A read-only, bounded observer for the text WhisprLocal just pasted.
///
/// Implementations return an opaque preparation identifier so callers never
/// retain or move Accessibility objects outside the main actor.
@MainActor
protocol PostPasteCorrectionMonitoring: AnyObject {
    func prepare(
        targetProcessIdentifier: pid_t?,
        targetBundleIdentifier: String?,
        excludedBundleIdentifiers: Set<String>
    ) -> UUID?

    func start(
        preparationID: UUID,
        pastedText: String,
        onEditedText: @escaping @MainActor (_ pasted: String, _ edited: String) -> Void
    )

    func cancel()
}

enum PastedTextTrackingUpdate: Equatable {
    case unchanged
    case outsideEdit
    case edited(String)
    case invalid
}

/// Tracks one pasted UTF-16 range through incremental text edits without
/// retaining or exposing any surrounding text after monitoring ends.
struct PastedTextRangeTracker {
    private(set) var document: String
    private(set) var range: NSRange
    let originalPastedText: String

    static func start(
        document: String,
        pastedText: String,
        preferredLocation: Int
    ) -> Self? {
        guard !pastedText.isEmpty,
              preferredLocation >= 0 else {
            return nil
        }
        let documentValue = document as NSString
        let pastedLength = (pastedText as NSString).length
        guard preferredLocation <= documentValue.length,
              pastedLength <= documentValue.length - preferredLocation else {
            return nil
        }
        let candidateRange = NSRange(
            location: preferredLocation,
            length: pastedLength
        )
        guard documentValue.substring(with: candidateRange) == pastedText else {
            return nil
        }
        return Self(
            document: document,
            range: candidateRange,
            originalPastedText: pastedText
        )
    }

    mutating func update(document newDocument: String) -> PastedTextTrackingUpdate {
        guard newDocument != document else { return .unchanged }

        let oldUnits = Array(document.utf16)
        let newUnits = Array(newDocument.utf16)
        var prefixLength = 0
        while prefixLength < oldUnits.count,
              prefixLength < newUnits.count,
              oldUnits[prefixLength] == newUnits[prefixLength] {
            prefixLength += 1
        }

        var suffixLength = 0
        while suffixLength < oldUnits.count - prefixLength,
              suffixLength < newUnits.count - prefixLength,
              oldUnits[oldUnits.count - suffixLength - 1]
                == newUnits[newUnits.count - suffixLength - 1] {
            suffixLength += 1
        }

        let oldChangedRange = NSRange(
            location: prefixLength,
            length: oldUnits.count - prefixLength - suffixLength
        )
        let newChangedLength = newUnits.count - prefixLength - suffixLength
        let delta = newChangedLength - oldChangedRange.length
        let trackedEnd = NSMaxRange(range)

        if oldChangedRange.location < range.location,
           NSMaxRange(oldChangedRange) <= range.location {
            range.location += delta
            guard range.location >= 0 else { return .invalid }
            document = newDocument
            return .outsideEdit
        }

        if oldChangedRange.location >= trackedEnd {
            document = newDocument
            return .outsideEdit
        }

        guard oldChangedRange.location >= range.location,
              NSMaxRange(oldChangedRange) <= trackedEnd else {
            return .invalid
        }

        let updatedLength = range.length + delta
        guard updatedLength >= 0 else { return .invalid }
        range.length = updatedLength
        let newValue = newDocument as NSString
        guard NSMaxRange(range) <= newValue.length else { return .invalid }
        let editedText = newValue.substring(with: range)
        document = newDocument
        return editedText == originalPastedText
            ? .unchanged
            : .edited(editedText)
    }
}

@MainActor
final class AccessibilityPostPasteCorrectionMonitor:
    PostPasteCorrectionMonitoring
{
    private struct Preparation {
        let id: UUID
        let processIdentifier: pid_t
        let element: AXUIElement
        let selectedRange: CFRange
    }

    private static let maximumDocumentLength = 100_000
    private static let maximumPastedLength = 4_000
    private static let observationDuration = Duration.seconds(15)
    private static let pollInterval = Duration.milliseconds(250)
    private static let editDebounce = Duration.milliseconds(650)

    private var preparation: Preparation?
    private var observationTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    func prepare(
        targetProcessIdentifier: pid_t?,
        targetBundleIdentifier: String?,
        excludedBundleIdentifiers: Set<String>
    ) -> UUID? {
        cancel()
        guard AXIsProcessTrusted(),
              let processIdentifier = targetProcessIdentifier,
              processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return nil
        }

        if let bundleIdentifier = targetBundleIdentifier?.lowercased(),
           excludedBundleIdentifiers.contains(bundleIdentifier) {
            correctionMonitorLogger.info(
                "Post-paste learning skipped for an excluded application"
            )
            return nil
        }

        let application = AXUIElementCreateApplication(processIdentifier)
        guard let element = accessibilityElement(
            from: application,
            attribute: kAXFocusedUIElementAttribute as CFString
        ), !isSecure(element),
           let document = accessibilityString(
               from: element,
               attribute: kAXValueAttribute as CFString
           ), document.utf16.count <= Self.maximumDocumentLength,
           let selectedRange = accessibilityRange(
               from: element,
               attribute: kAXSelectedTextRangeAttribute as CFString
           ), selectedRange.location >= 0,
           selectedRange.length >= 0,
           selectedRange.location + selectedRange.length <= document.utf16.count
        else {
            correctionMonitorLogger.debug(
                "Post-paste learning unavailable for the focused editor"
            )
            return nil
        }

        let id = UUID()
        preparation = Preparation(
            id: id,
            processIdentifier: processIdentifier,
            element: element,
            selectedRange: selectedRange
        )
        return id
    }

    func start(
        preparationID: UUID,
        pastedText: String,
        onEditedText: @escaping @MainActor (_ pasted: String, _ edited: String) -> Void
    ) {
        observationTask?.cancel()
        debounceTask?.cancel()
        guard let preparation,
              preparation.id == preparationID,
              !pastedText.isEmpty,
              pastedText.utf16.count <= Self.maximumPastedLength else {
            self.preparation = nil
            return
        }
        self.preparation = nil

        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now.advanced(
                by: Self.observationDuration
            )
            var tracker: PastedTextRangeTracker?

            while !Task.isCancelled, ContinuousClock.now < deadline {
                guard isStillFocused(preparation) else {
                    correctionMonitorLogger.debug(
                        "Post-paste observation ended after focus changed"
                    )
                    break
                }
                guard let currentDocument = accessibilityString(
                    from: preparation.element,
                    attribute: kAXValueAttribute as CFString
                ), currentDocument.utf16.count <= Self.maximumDocumentLength else {
                    break
                }

                if tracker == nil {
                    tracker = PastedTextRangeTracker.start(
                        document: currentDocument,
                        pastedText: pastedText,
                        preferredLocation: preparation.selectedRange.location
                    )
                    if tracker != nil {
                        correctionMonitorLogger.info(
                            "Post-paste correction observation armed"
                        )
                    }
                } else if var currentTracker = tracker {
                    let update = currentTracker.update(
                        document: currentDocument
                    )
                    tracker = currentTracker
                    switch update {
                    case .edited(let editedText):
                        scheduleDebouncedCallback(
                            pastedText: pastedText,
                            editedText: editedText,
                            onEditedText: onEditedText
                        )
                    case .invalid:
                        correctionMonitorLogger.info(
                            "Post-paste observation stopped after range drift"
                        )
                        return
                    case .unchanged, .outsideEdit:
                        break
                    }
                }

                try? await Task.sleep(for: Self.pollInterval)
            }
            observationTask = nil
        }
    }

    func cancel() {
        preparation = nil
        observationTask?.cancel()
        observationTask = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func scheduleDebouncedCallback(
        pastedText: String,
        editedText: String,
        onEditedText: @escaping @MainActor (_ pasted: String, _ edited: String) -> Void
    ) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: Self.editDebounce)
            guard !Task.isCancelled else { return }
            onEditedText(pastedText, editedText)
        }
    }

    private func isStillFocused(_ preparation: Preparation) -> Bool {
        guard NSRunningApplication(
            processIdentifier: preparation.processIdentifier
        )?.isTerminated == false else {
            return false
        }
        let application = AXUIElementCreateApplication(
            preparation.processIdentifier
        )
        guard let focused = accessibilityElement(
            from: application,
            attribute: kAXFocusedUIElementAttribute as CFString
        ) else {
            return false
        }
        return CFEqual(focused, preparation.element)
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        let subrole = accessibilityString(
            from: element,
            attribute: kAXSubroleAttribute as CFString
        )
        return subrole == kAXSecureTextFieldSubrole as String
    }

    private func accessibilityElement(
        from element: AXUIElement,
        attribute: CFString
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func accessibilityString(
        from element: AXUIElement,
        attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func accessibilityRange(
        from element: AXUIElement,
        attribute: CFString
    ) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let rangeValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range
    }
}
