@preconcurrency import AppKit
import SwiftUI

@MainActor
final class OverlayPanelController {
    static let contentSize = DictationOverlayView.pillSize

    private let panel: NSPanel
    private let hosting: NSHostingController<DictationOverlayView>
    private var isPresented = false
    private var lastPosition: OverlayPosition?
    private var lastStyle: IndicatorStyle?

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
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hosting
    }

    func update(
        for state: DictationState,
        position: OverlayPosition,
        style: IndicatorStyle = .floatingPill
    ) {
        guard state != .idle else {
            if isPresented {
                panel.orderOut(nil)
                isPresented = false
            }
            return
        }

        guard let screen = targetScreen(for: style) else { return }
        let notchLayout = style == .notch
            ? notchLayout(for: screen)
            : .fallback
        let size = DictationOverlayView.size(
            for: style,
            notchLayout: notchLayout
        )
        hosting.rootView = DictationOverlayView(
            state: state,
            style: style,
            notchLayout: notchLayout
        )
        hosting.view.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        panel.level = style == .notch ? .screenSaver : .floating
        if !isPresented || lastPosition != position || lastStyle != style {
            placePanel(
                size: size,
                at: position,
                style: style,
                screen: screen
            )
            lastPosition = position
            lastStyle = style
        }
        if !isPresented {
            presentPanel(style: style, on: screen)
            isPresented = true
        }
    }

    var contentControllerIdentity: ObjectIdentifier {
        ObjectIdentifier(hosting)
    }

    var displayedState: DictationState {
        hosting.rootView.state
    }

    private func placePanel(
        size: NSSize,
        at position: OverlayPosition,
        style: IndicatorStyle,
        screen: NSScreen
    ) {
        if style == .notch {
            panel.setFrameOrigin(
                NSPoint(
                    x: screen.frame.midX - size.width / 2,
                    y: screen.frame.maxY - size.height
                )
            )
        } else {
            panel.setFrameOrigin(
                position.origin(for: size, in: screen.visibleFrame)
            )
        }
    }

    private func targetScreen(for style: IndicatorStyle) -> NSScreen? {
        if style == .notch,
           let builtInNotchScreen = NSScreen.screens.first(where: {
               $0.safeAreaInsets.top > 0
           }) {
            return builtInNotchScreen
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first {
            NSMouseInRect(mouse, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func notchLayout(for screen: NSScreen) -> NotchOverlayLayout {
        guard screen.safeAreaInsets.top > 0,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            return .fallback
        }
        let physicalNotchWidth = screen.frame.width
            - leftArea.width
            - rightArea.width
        let menuBarDepth = max(
            screen.safeAreaInsets.top,
            screen.frame.maxY - screen.visibleFrame.maxY
        )
        return NotchOverlayLayout(
            width: physicalNotchWidth,
            topInset: menuBarDepth
        )
    }

    private func presentPanel(style: IndicatorStyle, on screen: NSScreen) {
        guard style == .notch else {
            panel.orderFrontRegardless()
            return
        }

        let finalFrame = panel.frame
        let hiddenFrame = NSRect(
            x: finalFrame.minX,
            y: screen.frame.maxY,
            width: finalFrame.width,
            height: finalFrame.height
        )
        panel.setFrame(hiddenFrame, display: true)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.34,
                1.0,
                0.64,
                1.0
            )
            panel.animator().setFrame(finalFrame, display: true)
        }
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
