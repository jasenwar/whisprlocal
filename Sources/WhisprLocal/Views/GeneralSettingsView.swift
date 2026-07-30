import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var environment: AppEnvironment
    @Bindable var preferences: AppPreferences
    @State private var launchError: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        preferences = environment.preferences
    }

    var body: some View {
        Form {
            Section("Hold to talk") {
                LabeledContent("Shortcut") {
                    Text("Hold Globe/Fn")
                }
                Text("Pressing any other key while Fn is held cancels recording, so normal Fn shortcuts continue to work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Microphone", selection: $preferences.audioInputMode) {
                    ForEach(AudioInputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(preferences.audioInputMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Pause media while dictating",
                    isOn: $preferences.pauseMediaDuringDictation
                )
                HStack {
                    Toggle(
                        "Play optional start and stop sounds",
                        isOn: $preferences.sounds
                    )
                    Spacer()
                    Button("Test start sound") {
                        environment.playReadySoundPreview()
                    }
                }
                Text("The floating overlay is the recording indicator. Sounds are off by default and do not control when recording begins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Paste automatically", isOn: $preferences.autoPaste)
                Toggle(
                    "Keep last dictation on clipboard",
                    isOn: $preferences.keepLastDictationOnClipboard
                )
                .disabled(!preferences.autoPaste)
                Text(
                    preferences.keepLastDictationOnClipboard
                        ? "The final corrected text remains available to paste again."
                        : "Your previous clipboard contents are restored after pasting."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Toggle(
                    "Conservative local grammar cleanup",
                    isOn: $preferences.cleanupEnabled
                )
                Text(
                    preferences.cleanupEnabled
                        ? "Uses the on-device Qwen2.5 model. If cleanup misses its deadline, the raw transcript is pasted immediately."
                        : "Cleanup is disabled. WhisprLocal will paste the raw Parakeet transcript."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                permissionRow(
                    title: "Microphone",
                    granted: environment.microphoneGranted,
                    action: environment.requestMicrophone
                )
                permissionRow(
                    title: "Accessibility",
                    granted: environment.accessibilityGranted,
                    action: environment.requestAccessibility
                )
            }

            Section("Visibility") {
                Toggle(
                    "Show WhisprLocal in the menu bar",
                    isOn: Binding(
                        get: { preferences.showMenuBarIcon },
                        set: { enabled in
                            environment.setMenuBarIconEnabled(enabled)
                        }
                    )
                )
                Picker("Overlay position", selection: $preferences.overlayPosition) {
                    ForEach(OverlayPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                Text("The Dock icon appears while Settings is open. With the menu-bar icon off, dictation continues running invisibly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local model") {
                HStack {
                    Label(
                        environment.modelStatus.isReady
                            ? "Parakeet Unified English is ready"
                            : "Parakeet model is missing",
                        systemImage: environment.modelStatus.isReady
                            ? "checkmark.circle.fill"
                            : "arrow.down.circle"
                    )
                    .foregroundStyle(environment.modelStatus.isReady ? .green : .primary)
                    Spacer()
                    if !environment.modelStatus.isReady {
                        Button("Download and verify") {
                            environment.downloadModel()
                        }
                        .disabled(environment.setupProgress != nil)
                    }
                }
                if let progress = environment.setupProgress {
                    ProgressView(value: progress)
                }
                if let message = environment.setupMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Cleanup model") {
                HStack {
                    Label(
                        environment.cleanupModelStatus.isReady
                            ? "Qwen2.5 3B local cleanup is ready"
                            : "Local cleanup model is missing",
                        systemImage: environment.cleanupModelStatus.isReady
                            ? "checkmark.circle.fill"
                            : "arrow.down.circle"
                    )
                    .foregroundStyle(
                        environment.cleanupModelStatus.isReady ? .green : .primary
                    )
                    Spacer()
                    if !environment.cleanupModelStatus.isReady {
                        Button("Download and verify") {
                            environment.downloadCleanupModel()
                        }
                        .disabled(environment.cleanupSetupProgress != nil)
                    }
                }
                if let progress = environment.cleanupSetupProgress {
                    ProgressView(value: progress)
                }
                if let message = environment.cleanupSetupMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(
                    "Runs entirely on this Mac through the bundled llama.cpp helper. Model download: 2.1 GB."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle(
                    "Launch invisibly at login",
                    isOn: Binding(
                        get: { environment.launchAtLogin.isEnabled },
                        set: { enabled in
                            do {
                                try environment.launchAtLogin.setEnabled(enabled)
                                launchError = nil
                            } catch {
                                launchError = error.localizedDescription
                            }
                        }
                    )
                )
                Text(environment.launchAtLogin.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            environment.refreshPermissions()
            environment.launchAtLogin.refresh()
        }
        .alert("Startup setting failed", isPresented: .constant(launchError != nil)) {
            Button("OK") { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Label(
                title,
                systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle"
            )
            .foregroundStyle(granted ? .green : .orange)
            Spacer()
            if !granted {
                Button("Allow", action: action)
            }
        }
    }
}
