@preconcurrency import AppKit
import SwiftUI

@MainActor
final class OverlayPanelController {
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
    }

    func update(for state: DictationState, position: OverlayPosition) {
        guard state != .idle else {
            panel.orderOut(nil)
            return
        }
        let hosting = NSHostingController(rootView: DictationOverlayView(state: state))
        hosting.view.layoutSubtreeIfNeeded()
        let size = hosting.view.fittingSize
        panel.contentViewController = hosting
        panel.setContentSize(size)
        placePanel(size: size, at: position)
        panel.orderFrontRegardless()
    }

    private func placePanel(size: NSSize, at position: OverlayPosition) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(position.origin(for: size, in: visible))
    }
}

extension OverlayPosition {
    func origin(
        for size: NSSize,
        in visibleFrame: NSRect,
        margin: CGFloat = 42
    ) -> NSPoint {
        let x: CGFloat
        switch self {
        case .topLeft, .bottomLeft:
            x = visibleFrame.minX + margin
        case .topCenter, .bottomCenter:
            x = visibleFrame.midX - size.width / 2
        case .topRight, .bottomRight:
            x = visibleFrame.maxX - size.width - margin
        }

        let y: CGFloat
        switch self {
        case .topLeft, .topCenter, .topRight:
            y = visibleFrame.maxY - size.height - margin
        case .bottomLeft, .bottomCenter, .bottomRight:
            y = visibleFrame.minY + margin
        }

        return NSPoint(x: x, y: y)
    }
}
