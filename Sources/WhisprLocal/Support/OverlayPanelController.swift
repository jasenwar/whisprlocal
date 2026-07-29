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

    func update(for state: DictationState) {
        guard state != .idle else {
            panel.orderOut(nil)
            return
        }
        let hosting = NSHostingController(rootView: DictationOverlayView(state: state))
        hosting.view.layoutSubtreeIfNeeded()
        let size = hosting.view.fittingSize
        panel.contentViewController = hosting
        panel.setContentSize(size)
        position(size: size)
        panel.orderFrontRegardless()
    }

    private func position(size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 42
        ))
    }
}
