import Foundation

enum BuildFlavor {
    static let productionBundleIdentifier = "com.jasenguerra.whisprlocal"
    static let hybridDevelopmentBundleIdentifier =
        "com.jasenguerra.whisprlocal.hybriddev"

    static var isHybridDevelopment: Bool {
        Bundle.main.bundleIdentifier == hybridDevelopmentBundleIdentifier
    }

    static var applicationSupportDirectoryName: String {
        isHybridDevelopment ? "WhisprLocal Hybrid Dev" : "WhisprLocal"
    }

    static var loginHelperBundleIdentifier: String {
        isHybridDevelopment
            ? "com.jasenguerra.whisprlocal.hybriddev.loginhelper"
            : "com.jasenguerra.whisprlocal.loginhelper"
    }
}
