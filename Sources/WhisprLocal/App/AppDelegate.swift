@preconcurrency import AppKit
import CoreServices
import OSLog

private let appLifecycleLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal",
    category: "Lifecycle"
)

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
        appLifecycleLogger.info(
            "Will finish launch: background=\(Self.isBackgroundLaunch) loginEvent=\(self.launchedAsLoginItem)"
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAsLoginItem = launchedAsLoginItem || Self.isLoginItemLaunch(
            NSAppleEventManager.shared().currentAppleEvent
        )
        let shouldRemainHidden = Self.isBackgroundLaunch || launchedAsLoginItem
        appLifecycleLogger.info(
            "Did finish launch: background=\(Self.isBackgroundLaunch) loginEvent=\(self.launchedAsLoginItem) hidden=\(shouldRemainHidden)"
        )
        AppEnvironment.shared.start()
        guard !shouldRemainHidden else { return }
        appLifecycleLogger.info("Presenting Settings after manual launch")
        showSettings()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        appLifecycleLogger.info(
            "Handling manual reopen: visibleWindows=\(flag)"
        )
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

    static var isBackgroundLaunch: Bool {
        CommandLine.arguments.contains("--background")
    }
}
