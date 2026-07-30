@preconcurrency import AppKit
import OSLog

private let loginHelperLogger = Logger(
    subsystem: "com.jasenguerra.whisprlocal.loginhelper",
    category: "Lifecycle"
)

@main
enum LoginHelperMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = LoginHelperDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.prohibited)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class LoginHelperDelegate: NSObject, NSApplicationDelegate {
    private static let mainBundleIdentifier = "com.jasenguerra.whisprlocal"

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.mainBundleIdentifier
        ).isEmpty else {
            loginHelperLogger.info("Main application is already running")
            NSApp.terminate(nil)
            return
        }

        let mainApplicationURL = Self.mainApplicationURL
        guard Bundle(url: mainApplicationURL)?.bundleIdentifier
            == Self.mainBundleIdentifier else {
            loginHelperLogger.error("Main application bundle could not be resolved")
            NSApp.terminate(nil)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--background"]
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.promptsUserIfNeeded = false

        loginHelperLogger.info("Launching main application in background")
        NSWorkspace.shared.openApplication(
            at: mainApplicationURL,
            configuration: configuration
        ) { _, error in
            if let error {
                loginHelperLogger.error(
                    "Background launch failed: \(error.localizedDescription, privacy: .public)"
                )
            } else {
                loginHelperLogger.info("Background launch request succeeded")
            }
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    private static var mainApplicationURL: URL {
        var url = Bundle.main.bundleURL
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        return url
    }
}
