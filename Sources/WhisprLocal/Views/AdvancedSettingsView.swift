import SwiftUI

struct AdvancedSettingsView: View {
    @Bindable var environment: AppEnvironment
    @Bindable var preferences: AppPreferences
    @State private var exclusionsText: String

    init(environment: AppEnvironment) {
        self.environment = environment
        preferences = environment.preferences
        _exclusionsText = State(
            initialValue: environment.preferences
                .excludedContextBundleIdentifiers
                .joined(separator: "\n")
        )
    }

    var body: some View {
        Form {
            Section("Local Fallback") {
                modelRow(
                    title: environment.modelStatus.isReady
                        ? "Parakeet Unified English is ready"
                        : "Parakeet model is missing",
                    ready: environment.modelStatus.isReady,
                    buttonTitle: "Download and Verify",
                    progress: environment.setupProgress,
                    message: environment.setupMessage,
                    action: environment.downloadModel
                )
                modelRow(
                    title: environment.cleanupModelStatus.isReady
                        ? "Qwen2.5 3B cleanup is ready"
                        : "Local cleanup model is missing",
                    ready: environment.cleanupModelStatus.isReady,
                    buttonTitle: "Download and Verify",
                    progress: environment.cleanupSetupProgress,
                    message: environment.cleanupSetupMessage,
                    action: environment.downloadCleanupModel
                )
                Text("Keeping both models installed makes Groq fallback immediate. Local transcription is also used whenever Fully Local mode is selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Context Exclusions") {
                Text("Enter one bundle identifier per line. No window image or text is collected from excluded apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $exclusionsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110)
                    .onChange(of: exclusionsText) { _, value in
                        preferences.excludedContextBundleIdentifiers = value
                            .split(whereSeparator: \Character.isNewline)
                            .map {
                                $0.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                )
                            }
                            .filter { !$0.isEmpty }
                    }
            }

            Section("Custom Cleanup Prompt") {
                TextEditor(text: $preferences.customGroqCleanupPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 145)
                Text("Leave blank to use WhisprLocal’s tested conservative prompt. A custom prompt replaces it completely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom Context Prompt") {
                TextEditor(text: $preferences.customGroqContextPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 130)
                Text("Leave blank to use the default two-sentence context summary. Window content is always treated as untrusted data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced")
    }

    @ViewBuilder
    private func modelRow(
        title: String,
        ready: Bool,
        buttonTitle: String,
        progress: Double?,
        message: String?,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    title,
                    systemImage: ready
                        ? "checkmark.circle.fill"
                        : "arrow.down.circle"
                )
                .foregroundStyle(ready ? .green : .primary)
                Spacer()
                if !ready {
                    Button(buttonTitle, action: action)
                        .disabled(progress != nil)
                }
            }
            if let progress {
                ProgressView(value: progress)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
