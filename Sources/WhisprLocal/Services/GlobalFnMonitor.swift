@preconcurrency import AppKit

@MainActor
final class GlobalFnMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onInterrupt: (() -> Void)?

    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var fnHeld = false

    func start() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            Task { @MainActor in self?.handleFlags(event) }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] _ in
            Task { @MainActor in self?.handleInterruption() }
        }
    }

    func stop() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        flagsMonitor = nil
        keyMonitor = nil
        fnHeld = false
    }

    private func handleFlags(_ event: NSEvent) {
        let nowHeld = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .contains(.function)
        if nowHeld, !fnHeld {
            fnHeld = true
            onPress?()
        } else if !nowHeld, fnHeld {
            fnHeld = false
            onRelease?()
        }
    }

    private func handleInterruption() {
        guard fnHeld else { return }
        fnHeld = false
        onInterrupt?()
    }
}
