import SwiftUI

@main
struct WhisprLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView(environment: AppEnvironment.shared)
                .frame(minWidth: 900, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    SettingsWindowController.shared.present()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
