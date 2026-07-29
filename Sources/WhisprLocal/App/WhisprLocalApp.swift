import SwiftUI

@main
struct WhisprLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView(environment: AppEnvironment.shared)
                .frame(minWidth: 720, minHeight: 520)
        }
    }
}
