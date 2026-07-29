import AppKit

var mainApplicationURL = Bundle.main.bundleURL
for _ in 0..<4 {
    mainApplicationURL.deleteLastPathComponent()
}

let configuration = NSWorkspace.OpenConfiguration()
configuration.arguments = ["--background"]
configuration.activates = false
NSWorkspace.shared.openApplication(
    at: mainApplicationURL,
    configuration: configuration
) { _, _ in
    Task { @MainActor in
        NSApp.terminate(nil)
    }
}
NSApplication.shared.run()
