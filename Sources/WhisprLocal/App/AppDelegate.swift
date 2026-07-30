@preconcurrency import AppKit
import CoreServices

@MainActor
protocol LoginRelaunchControlling: AnyObject {
    func disableRelaunchOnLogin()
}

extension NSApplication: LoginRelaunchControlling {}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAsLoginItem = false
    private let relaunchController: any LoginRelaunchControlling

    override init() {
        relaunchController = NSApplication.shared
        super.init()
    }

    init(relaunchController: any LoginRelaunchControlling) {
        self.relaunchController = relaunchController
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // SMAppService owns login startup; suppress the separate session-restore reopen.
        relaunchController.disableRelaunchOnLogin()
        launchedAsLoginItem = Self.isLoginItemLaunch(
            NSAppleEventManager.shared().currentAppleEvent
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAsLoginItem = launchedAsLoginItem || Self.isLoginItemLaunch(
            NSAppleEventManager.shared().currentAppleEvent
        )
        AppEnvironment.shared.start()
        guard !CommandLine.arguments.contains("--background"),
              !launchedAsLoginItem else { return }
        showSettings()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppEnvironment.shared.refreshPermissions()
        AppEnvironment.shared.launchAtLogin.refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        Task {
            await AppEnvironment.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func showSettings() {
        SettingsWindowController.shared.present()
    }

    static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event,
              event.eventClass == kCoreEventClass,
              event.eventID == kAEOpenApplication else {
            return false
        }
        return event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
    }
}
