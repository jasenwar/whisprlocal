@preconcurrency import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WhisprLocal Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(
            rootView: SettingsRootView(environment: AppEnvironment.shared)
        )
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
