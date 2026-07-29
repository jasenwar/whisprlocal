import AppKit
import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
            Text("WhisprLocal")
                .font(.title.bold())
            Text("Private, native, local dictation for macOS.")
                .foregroundStyle(.secondary)
            Text("No accounts, billing, telemetry, updater, Docker, Dock icon, or menu-bar icon.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Quit WhisprLocal") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
