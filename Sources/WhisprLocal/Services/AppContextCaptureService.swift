@preconcurrency import AppKit
import ApplicationServices
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class AppContextCaptureService {
    var hasScreenCapturePermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenCapturePermission() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
           ) {
            NSWorkspace.shared.open(url)
        }
    }

    func capture(
        level: ContextAwarenessLevel,
        excludedBundleIdentifiers: Set<String>
    ) async -> CapturedAppContext? {
        guard level != .off,
              let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let bundleIdentifier = application.bundleIdentifier
        if let bundleIdentifier,
           excludedBundleIdentifiers.contains(bundleIdentifier.lowercased()) {
            return CapturedAppContext(
                appName: application.localizedName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: nil,
                selectedText: nil,
                screenshotJPEG: nil,
                captureNote: "Context is disabled for this application."
            )
        }

        let appElement = AXUIElementCreateApplication(
            application.processIdentifier
        )
        let focusedWindow = accessibilityElement(
            from: appElement,
            attribute: kAXFocusedWindowAttribute as CFString
        )
        let windowTitle = focusedWindow.flatMap {
            accessibilityString(
                from: $0,
                attribute: kAXTitleAttribute as CFString
            )
        } ?? application.localizedName
        let focusedElement = accessibilityElement(
            from: appElement,
            attribute: kAXFocusedUIElementAttribute as CFString
        )
        let selectedText = focusedElement.flatMap {
            accessibilityString(
                from: $0,
                attribute: kAXSelectedTextAttribute as CFString
            )
        }

        guard level == .focusedWindow else {
            return CapturedAppContext(
                appName: application.localizedName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                selectedText: selectedText,
                screenshotJPEG: nil,
                captureNote: nil
            )
        }

        guard hasScreenCapturePermission else {
            return CapturedAppContext(
                appName: application.localizedName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                selectedText: selectedText,
                screenshotJPEG: nil,
                captureNote: "Screen Recording permission is unavailable; using text context only."
            )
        }

        let screenshot: Data?
        if let focusedWindow {
            screenshot = await captureFocusedWindow(
                processIdentifier: application.processIdentifier,
                focusedWindow: focusedWindow,
                windowTitle: windowTitle
            )
        } else {
            screenshot = nil
        }
        return CapturedAppContext(
            appName: application.localizedName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: selectedText,
            screenshotJPEG: screenshot,
            captureNote: screenshot == nil
                ? "The focused window could not be captured; using text context only."
                : nil
        )
    }

    private func captureFocusedWindow(
        processIdentifier: pid_t,
        focusedWindow: AXUIElement,
        windowTitle: String?
    ) async -> Data? {
        guard let focusedBounds = bounds(of: focusedWindow),
              let content = await shareableContent() else {
            return nil
        }

        let candidate = content.windows.compactMap { window -> WindowCandidate? in
            guard window.owningApplication?.processID == processIdentifier else {
                return nil
            }
            let intersection = window.frame.intersection(focusedBounds)
            guard !intersection.isNull else { return nil }
            let overlap = intersection.width * intersection.height
            let titleMatches = windowTitle.map {
                window.title?.localizedCaseInsensitiveContains($0) == true
            } ?? false
            return WindowCandidate(
                window: window,
                overlap: overlap,
                titleMatches: titleMatches
            )
        }
        .sorted {
            if $0.titleMatches != $1.titleMatches {
                return $0.titleMatches
            }
            return $0.overlap > $1.overlap
        }
        .first

        guard let candidate else {
            return nil
        }
        let filter = SCContentFilter(
            desktopIndependentWindow: candidate.window
        )
        let configuration = SCStreamConfiguration()
        configuration.width = max(
            1,
            min(2_048, Int(candidate.window.frame.width * 2))
        )
        configuration.height = max(
            1,
            min(2_048, Int(candidate.window.frame.height * 2))
        )
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) else { return nil }
        return jpegData(from: image, maximumDimension: 1_024)
    }

    private func shareableContent() async -> SCShareableContent? {
        try? await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
    }

    private func jpegData(
        from image: CGImage,
        maximumDimension: CGFloat
    ) -> Data? {
        let sourceSize = CGSize(width: image.width, height: image.height)
        let scale = min(
            1,
            maximumDimension / max(sourceSize.width, sourceSize.height)
        )
        let targetSize = CGSize(
            width: max(1, (sourceSize.width * scale).rounded()),
            height: max(1, (sourceSize.height * scale).rounded())
        )
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(targetSize.width),
                height: Int(targetSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(origin: .zero, size: targetSize)
        )
        guard let resized = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: resized).representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.55]
        )
    }

    private func bounds(of element: AXUIElement) -> CGRect? {
        guard let point = accessibilityPoint(
            from: element,
            attribute: kAXPositionAttribute as CFString
        ), let size = accessibilitySize(
            from: element,
            attribute: kAXSizeAttribute as CFString
        ) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    private func accessibilityElement(
        from element: AXUIElement,
        attribute: CFString
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
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
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(4_000))
    }

    private func accessibilityPoint(
        from element: AXUIElement,
        attribute: CFString
    ) -> CGPoint? {
        var value: CFTypeRef?
        var point = CGPoint.zero
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(
                unsafeDowncast(value, to: AXValue.self),
                .cgPoint,
                &point
              ) else {
            return nil
        }
        return point
    }

    private func accessibilitySize(
        from element: AXUIElement,
        attribute: CFString
    ) -> CGSize? {
        var value: CFTypeRef?
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(
                unsafeDowncast(value, to: AXValue.self),
                .cgSize,
                &size
              ) else {
            return nil
        }
        return size
    }
}

private struct WindowCandidate {
    let window: SCWindow
    let overlap: CGFloat
    let titleMatches: Bool
}
