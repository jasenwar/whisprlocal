import SwiftUI

struct IntelligenceSettingsView: View {
    @Bindable var environment: AppEnvironment
    @Bindable var preferences: AppPreferences
    @State private var apiKey = ""

    init(environment: AppEnvironment) {
        self.environment = environment
        preferences = environment.preferences
    }

    var body: some View {
        Form {
            Section("Processing Mode") {
                Picker("Mode", selection: $preferences.processingMode) {
                    ForEach(ProcessingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(preferences.processingMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if preferences.processingMode == .groqPreferred {
                    Label(
                        "Local transcription and cleanup remain ready as the automatic fallback.",
                        systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Label(
                        "Fully Local makes no runtime network requests.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                }
            }

            Section("Groq") {
                statusRow
                if !environment.hasGroqAPIKey {
                    SecureField("gsk_…", text: $apiKey)
                        .textContentType(.password)
                    HStack {
                        Button("Save API Key") {
                            environment.saveGroqAPIKey(apiKey)
                            apiKey = ""
                        }
                        .disabled(apiKey.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty)
                        Link(
                            "Create a Groq key",
                            destination: URL(
                                string: "https://console.groq.com/keys"
                            )!
                        )
                    }
                } else {
                    HStack {
                        Button("Test Connection") {
                            environment.testGroqConnection()
                        }
                        .disabled(environment.isTestingGroqConnection)
                        if environment.isTestingGroqConnection {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                        Button("Disconnect", role: .destructive) {
                            environment.removeGroqAPIKey()
                        }
                    }
                }
                if let message = environment.groqConnectionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("The key is stored in your Mac’s Keychain, not in the WhisprLocal database or settings file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Groq Models") {
                Picker(
                    "Transcription",
                    selection: $preferences.groqTranscriptionModel
                ) {
                    ForEach(GroqTranscriptionModel.allCases) { model in
                        Text(model.title).tag(model)
                    }
                }
                Picker("Cleanup", selection: $preferences.groqCleanupModel) {
                    ForEach(GroqCleanupModel.allCases) { model in
                        Text(model.title).tag(model)
                    }
                }
                Text("Whisper Large V3 and GPT-OSS 20B are the recommended accuracy/speed balance. Model changes apply to the next dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(preferences.processingMode == .fullyLocal)

            Section("Cleanup") {
                Toggle(
                    "Conservative grammar cleanup",
                    isOn: $preferences.cleanupEnabled
                )
                Text(cleanupDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Context Awareness") {
                Picker("Context", selection: $preferences.contextAwarenessLevel) {
                    ForEach(ContextAwarenessLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                Text(preferences.contextAwarenessLevel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if preferences.contextAwarenessLevel == .focusedWindow {
                    HStack {
                        Label(
                            "Screen Recording",
                            systemImage: environment.screenCaptureGranted
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle"
                        )
                        .foregroundStyle(
                            environment.screenCaptureGranted ? .green : .orange
                        )
                        Spacer()
                        if !environment.screenCaptureGranted {
                            Button("Allow") {
                                environment.requestScreenCapture()
                            }
                        }
                    }
                }
                Label(
                    "Only the focused window is captured. The image stays in memory for the current request and is never saved.",
                    systemImage: "eye.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .disabled(preferences.processingMode == .fullyLocal)
        }
        .formStyle(.grouped)
        .navigationTitle("Intelligence")
        .onAppear {
            environment.refreshGroqStatus()
            environment.refreshPermissions()
        }
    }

    private var cleanupDetail: String {
        guard preferences.cleanupEnabled else {
            return "Off: WhisprLocal pastes the transcript without AI cleanup."
        }
        return preferences.processingMode == .groqPreferred
            ? "Groq cleans the transcript first. If Groq is limited or unavailable, the existing local Qwen cleanup takes over."
            : "Uses the existing on-device Qwen2.5 cleanup model."
    }

    private var statusRow: some View {
        HStack {
            Label(
                environment.groqStatus.message,
                systemImage: statusSymbol
            )
            .foregroundStyle(statusColor)
            Spacer()
            if let retryAt = environment.groqStatus.retryAt {
                Text(retryAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusSymbol: String {
        switch environment.groqStatus.state {
        case .ready: "checkmark.circle.fill"
        case .missingCredential: "key"
        case .temporarilyUnavailable: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }

    private var statusColor: Color {
        switch environment.groqStatus.state {
        case .ready: .green
        case .missingCredential: .secondary
        case .temporarilyUnavailable: .orange
        }
    }
}
