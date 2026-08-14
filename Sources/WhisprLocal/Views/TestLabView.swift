@preconcurrency import AppKit
import SwiftUI

struct TestLabView: View {
    @Bindable var environment: AppEnvironment
    @State private var sampleText = "hey can you clean this up i think the meeting is at three thirty tomorrow and um send it to Jasen"
    @State private var showCleanupPrompt = false
    @State private var showContextPrompt = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                cleanupCard
                contextCard
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("Test Lab")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Test Groq before using it everywhere")
                .font(.title2.weight(.semibold))
            Text("These tests do not paste, create history, or save the window screenshot.")
                .foregroundStyle(.secondary)
        }
    }

    private var cleanupCard: some View {
        GroupBox("Cleanup") {
            VStack(alignment: .leading, spacing: 14) {
                TextEditor(text: $sampleText)
                    .font(.body)
                    .frame(minHeight: 105)
                    .padding(6)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("Run Groq Cleanup") {
                        environment.runGroqCleanupTest(text: sampleText)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(environment.isRunningCleanupTest)
                    if environment.isRunningCleanupTest {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Text(environment.preferences.groqCleanupModel.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = environment.cleanupTestError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let result = environment.cleanupTestResult {
                    Divider()
                    comparison(result)
                    DisclosureGroup(
                        "Prompt sent to Groq",
                        isExpanded: $showCleanupPrompt
                    ) {
                        Text(result.prompt)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(8)
        }
    }

    private var contextCard: some View {
        GroupBox("Context Awareness") {
            VStack(alignment: .leading, spacing: 14) {
                Text("WhisprLocal will briefly hide Settings, inspect the app underneath it, capture only that focused window, and then return here with the result.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Test Focused Window") {
                        Task {
                            await SettingsWindowController.shared
                                .runContextTestWithSettingsHidden()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(environment.isRunningContextTest)
                    if environment.isRunningContextTest {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Label(
                        environment.screenCaptureGranted
                            ? "Screen Recording allowed"
                            : "Screen Recording needed",
                        systemImage: environment.screenCaptureGranted
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        environment.screenCaptureGranted ? .green : .orange
                    )
                }
                if let error = environment.contextTestError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let result = environment.contextTestResult {
                    Divider()
                    contextResult(result)
                }
            }
            .padding(8)
        }
    }

    private func comparison(_ result: CleanupTestResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(result.engine, systemImage: "sparkles")
                Spacer()
                Text("\(result.latency.formatted(.number.precision(.fractionLength(2)))) s")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                resultPane(title: "Original", text: result.rawText)
                resultPane(title: "Cleaned", text: result.cleanedText)
            }
        }
    }

    private func contextResult(_ result: DictationContext) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let data = result.screenshotJPEG,
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(nsColor: .separatorColor))
                    )
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                metadataRow("Application", result.appName ?? "Unknown")
                metadataRow("Window", result.windowTitle ?? "Unknown")
                metadataRow("Selected text", result.selectedText ?? "None")
                metadataRow("Model", result.inferenceModel ?? "Metadata only")
                if let latency = result.inferenceLatency {
                    metadataRow(
                        "Latency",
                        latency.formatted(.number.precision(.fractionLength(2))) + " s"
                    )
                }
            }
            Text("Context summary")
                .font(.headline)
            Text(result.summary)
                .textSelection(.enabled)
            if let note = result.captureNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let prompt = result.inferencePrompt {
                DisclosureGroup(
                    "Prompt sent to Groq",
                    isExpanded: $showContextPrompt
                ) {
                    Text(prompt)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func resultPane(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
