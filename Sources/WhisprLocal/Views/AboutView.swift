import AppKit
import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
            Text("WhisprLocal")
                .font(.title.bold())
            Text("Privacy-first, native, local dictation for macOS.")
                .foregroundStyle(.secondary)
            Text(versionText)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("No accounts, billing, telemetry, updater, or Docker. The Dock icon is temporary and the menu-bar icon is optional.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Quit WhisprLocal") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .navigationTitle("About")
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String ?? "Unknown"
        return "Version \(version) (\(build))"
    }
}
