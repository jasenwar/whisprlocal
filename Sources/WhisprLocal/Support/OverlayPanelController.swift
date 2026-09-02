@preconcurrency import AppKit
import SwiftUI

@MainActor
final class OverlayPanelController {
    static let contentSize = DictationOverlayView.pillSize

    private let panel: NSPanel
    private let hosting: NSHostingController<DictationOverlayView>
    private let learningNoticeDuration: Duration
    private var isPresented = false
    private var lastPosition: OverlayPosition?
    private var lastStyle: IndicatorStyle?
    private var lastSize: NSSize?
    private var currentState: DictationState = .idle
    private var activeLearningEvent: DictionaryLearningEvent?
    private var pendingLearningEvents: [DictionaryLearningEvent] = []
    private var learningDismissalTask: Task<Void, Never>?
    private var preferredPosition: OverlayPosition = .topCenter
    private var preferredStyle: IndicatorStyle = .floatingPill

    init(learningNoticeDuration: Duration = .seconds(3)) {
        self.learningNoticeDuration = learningNoticeDuration
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
        currentState = state
        preferredPosition = position
        preferredStyle = style

        guard state != .idle else {
            if activeLearningEvent != nil { return }
            if !pendingLearningEvents.isEmpty {
                showNextLearningNotice()
            } else {
                hidePanel()
            }
            return
        }

        if let activeLearningEvent {
            pendingLearningEvents.insert(activeLearningEvent, at: 0)
            self.activeLearningEvent = nil
        }
        learningDismissalTask?.cancel()
        learningDismissalTask = nil
        present(
            .dictation(state),
            position: position,
            style: style
        )
    }

    /// Shows a database-confirmed learning event without activating WhisprLocal.
    /// Active dictation always wins; interrupted notices resume after idle.
    func showLearningNotice(
        _ event: DictionaryLearningEvent,
        position: OverlayPosition,
        style: IndicatorStyle = .floatingPill
    ) {
        guard !event.corrections.isEmpty else { return }
        preferredPosition = position
        preferredStyle = style

        let notices = event.corrections.count == 1
            ? [event]
            : event.corrections.map {
                DictionaryLearningEvent(corrections: [$0])
            }
        for notice in notices {
            enqueueLearningNotice(notice)
        }
    }

    private func enqueueLearningNotice(_ event: DictionaryLearningEvent) {
        if currentState != .idle || activeLearningEvent != nil {
            pendingLearningEvents.append(event)
        } else {
            displayLearningNotice(event)
        }
    }

    private func present(
        _ presentation: DictationOverlayPresentation,
        position: OverlayPosition,
        style: IndicatorStyle
    ) {
        guard let screen = targetScreen(for: style) else { return }
        var notchLayout = style == .notch
            ? notchLayout(for: screen)
            : .fallback
        if style == .notch, presentation.isLearningNotice {
            notchLayout = NotchOverlayLayout(
                width: notchLayout.width,
                topInset: notchLayout.topInset,
                dropDownHeight: 54
            )
        }
        let size = DictationOverlayView.size(
            for: presentation,
            style: style,
            notchLayout: notchLayout
        )
        hosting.rootView = DictationOverlayView(
            presentation: presentation,
            style: style,
            notchLayout: notchLayout
        )
        hosting.view.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        panel.level = style == .notch ? .screenSaver : .floating
        if !isPresented
            || lastPosition != position
            || lastStyle != style
            || lastSize != size {
            placePanel(
                size: size,
                at: position,
                style: style,
                screen: screen
            )
            lastPosition = position
            lastStyle = style
            lastSize = size
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

    var displayedLearningEvent: DictionaryLearningEvent? {
        activeLearningEvent
    }

    var queuedLearningEventCount: Int {
        pendingLearningEvents.count
    }

    private func displayLearningNotice(_ event: DictionaryLearningEvent) {
        activeLearningEvent = event
        present(
            .dictionaryLearning(event),
            position: preferredPosition,
            style: preferredStyle
        )

        learningDismissalTask?.cancel()
        let duration = learningNoticeDuration
        learningDismissalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            self?.finishLearningNotice(id: event.id)
        }
    }

    private func finishLearningNotice(id: UUID) {
        guard activeLearningEvent?.id == id else { return }
        activeLearningEvent = nil
        learningDismissalTask = nil
        if currentState == .idle, !pendingLearningEvents.isEmpty {
            showNextLearningNotice()
        } else if currentState == .idle {
            hidePanel()
        }
    }

    private func showNextLearningNotice() {
        guard currentState == .idle,
              activeLearningEvent == nil,
              !pendingLearningEvents.isEmpty else {
            return
        }
        displayLearningNotice(pendingLearningEvents.removeFirst())
    }

    private func hidePanel() {
        guard isPresented else { return }
        panel.orderOut(nil)
        isPresented = false
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
