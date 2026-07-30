@preconcurrency import AVFoundation
@preconcurrency import ApplicationServices
import AppKit

@MainActor
protocol DictationPermissionChecking: AnyObject {
    var microphoneGranted: Bool { get }
    func requestMicrophone() async -> Bool
}

@MainActor
final class PermissionService: DictationPermissionChecking {
    var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    func requestMicrophone() async -> Bool {
        if microphoneGranted { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    func requestAccessibility() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func openMicrophoneSettings() {
        openSettings("Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openSettings("Privacy_Accessibility")
    }

    private func openSettings(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
