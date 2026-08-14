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
            Section("Hold to Talk") {
                LabeledContent("Shortcut", value: "Hold Globe/Fn")
                Picker("Microphone", selection: $preferences.microphoneMode) {
                    Text("System Default").tag(MicrophoneMode.systemDefault)
                    Text(
                        AudioInputDeviceResolver.builtInInputDeviceName()
                            ?? "Mac Microphone"
                    )
                    .tag(MicrophoneMode.builtIn)
                }
                Text(microphoneDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Pause media while dictating",
                    isOn: $preferences.pauseMediaDuringDictation
                )
                HStack {
                    Toggle(
                        "Play start and stop sounds",
                        isOn: $preferences.sounds
                    )
                    Spacer()
                    Button("Preview") { environment.playReadySoundPreview() }
                }
            }

            Section("Pasting") {
                Toggle("Paste automatically", isOn: $preferences.autoPaste)
                Toggle(
                    "Keep last dictation on clipboard",
                    isOn: $preferences.keepLastDictationOnClipboard
                )
                .disabled(!preferences.autoPaste)
                Text(
                    preferences.keepLastDictationOnClipboard
                        ? "The final text stays on the clipboard so you can paste it again."
                        : "Your prior clipboard contents are restored after the automatic paste."
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

            Section("Indicator") {
                Picker("Style", selection: $preferences.indicatorStyle) {
                    ForEach(IndicatorStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Picker("Pill position", selection: $preferences.overlayPosition) {
                    ForEach(OverlayPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                .disabled(preferences.indicatorStyle == .notch)
                Text(
                    preferences.indicatorStyle == .notch
                        ? "The indicator extends directly below the built-in display notch."
                        : "The proven floating pill remains the default and can be placed anywhere along the screen edge."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Text("WhisprLocal keeps working invisibly when Settings is closed and the menu-bar icon is off. The Dock icon appears only while Settings is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle(
                    "Launch invisibly at login",
                    isOn: Binding(
                        get: { environment.launchAtLogin.isEnabled },
                        set: { enabled in
                            setLaunchAtLogin(enabled)
                        }
                    )
                )
                Text(environment.launchAtLogin.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear {
            environment.refreshPermissions()
            environment.launchAtLogin.refresh()
        }
        .alert(
            "Startup setting failed",
            isPresented: Binding(
                get: { launchError != nil },
                set: { if !$0 { launchError = nil } }
            )
        ) {
            Button("OK") { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }

    private var microphoneDetail: String {
        preferences.microphoneMode == .systemDefault
            ? "Follows macOS Sound settings, including AirPods. Bluetooth microphones can take a moment to switch into recording mode."
            : "Uses the Mac’s built-in microphone even while audio plays through AirPods. This is the fastest and most reliable option."
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try environment.launchAtLogin.setEnabled(enabled)
            launchError = nil
        } catch {
            launchError = error.localizedDescription
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
                systemImage: granted
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle"
            )
            .foregroundStyle(granted ? .green : .orange)
            Spacer()
            if !granted {
                Button("Allow", action: action)
            }
        }
    }
}
