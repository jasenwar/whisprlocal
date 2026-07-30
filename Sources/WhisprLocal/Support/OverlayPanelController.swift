@preconcurrency import AppKit
import SwiftUI

@MainActor
final class OverlayPanelController {
    static let contentSize = DictationOverlayView.contentSize

    private let panel: NSPanel
    private let hosting: NSHostingController<DictationOverlayView>
    private var isPresented = false
    private var lastPosition: OverlayPosition?

    init() {
        let hosting = NSHostingController(
            rootView: DictationOverlayView(state: .preparing)
        )
        hosting.view.frame = NSRect(
            origin: .zero,
            size: Self.contentSize
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.hosting = hosting
        self.panel = panel

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentViewController = hosting
    }

    func update(for state: DictationState, position: OverlayPosition) {
        guard state != .idle else {
            if isPresented {
                panel.orderOut(nil)
                isPresented = false
            }
            return
        }

        hosting.rootView = DictationOverlayView(state: state)
        if !isPresented || lastPosition != position {
            placePanel(size: Self.contentSize, at: position)
            lastPosition = position
        }
        if !isPresented {
            panel.orderFrontRegardless()
            isPresented = true
        }
    }

    var contentControllerIdentity: ObjectIdentifier {
        ObjectIdentifier(hosting)
    }

    var displayedState: DictationState {
        hosting.rootView.state
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
