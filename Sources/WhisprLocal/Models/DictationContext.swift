import Foundation

struct DictationContext: Sendable {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let selectedText: String?
    let summary: String
    let screenshotJPEG: Data?
    let captureNote: String?
    let inferencePrompt: String?
    let inferenceModel: String?
    let inferenceLatency: TimeInterval?

    var metadataDescription: String {
        """
        Application: \(appName ?? "Unknown")
        Bundle identifier: \(bundleIdentifier ?? "Unknown")
        Window title: \(windowTitle ?? "Unknown")
        Selected text: \(selectedText ?? "None")
        """
    }
}

struct CapturedAppContext: Sendable {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let selectedText: String?
    let screenshotJPEG: Data?
    let captureNote: String?

    var metadataDescription: String {
        """
        Application: \(appName ?? "Unknown")
        Bundle identifier: \(bundleIdentifier ?? "Unknown")
        Window title: \(windowTitle ?? "Unknown")
        Selected text: \(selectedText ?? "None")
        """
    }
}

struct CleanupTestResult: Sendable {
    let rawText: String
    let cleanedText: String
    let engine: String
    let prompt: String
    let latency: TimeInterval
}
