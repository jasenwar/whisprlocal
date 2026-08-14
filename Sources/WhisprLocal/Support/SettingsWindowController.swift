@preconcurrency import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var permissionRefreshTask: Task<Void, Never>?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WhisprLocal Settings"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.contentView = NSHostingView(
            rootView: SettingsRootView(environment: AppEnvironment.shared)
        )
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        NSApp.setActivationPolicy(.regular)
        AppEnvironment.shared.refreshPermissions()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPermissionRefresh()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        AppEnvironment.shared.refreshPermissions()
        startPermissionRefresh()
    }

    func windowWillClose(_ notification: Notification) {
        permissionRefreshTask?.cancel()
        permissionRefreshTask = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func runContextTestWithSettingsHidden() async {
        window?.orderOut(nil)
        NSApp.hide(nil)
        try? await Task.sleep(for: .milliseconds(450))
        await AppEnvironment.shared.runContextTest()
        NSApp.unhide(nil)
        present()
    }

    private func startPermissionRefresh() {
        guard permissionRefreshTask == nil else { return }
        permissionRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                AppEnvironment.shared.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
