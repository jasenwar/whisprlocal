@preconcurrency import AppKit

@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?

    func setEnabled(_ enabled: Bool) {
        if enabled {
            installIfNeeded()
        } else {
            removeIfNeeded()
        }
    }

    private func installIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "WhisprLocal"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "WhisprLocal"
        }

        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Open Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit WhisprLocal",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func removeIfNeeded() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.present()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
