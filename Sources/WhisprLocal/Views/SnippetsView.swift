import SwiftUI

struct SnippetsView: View {
    @Bindable var store: SnippetStore
    @State private var trigger = ""
    @State private var replacement = ""

    private var canSave: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !replacement.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snippets")
                .font(.title2.weight(.semibold))

            Text("Turn a short dictated phrase into reusable text, including signatures and multi-line templates.")
                .foregroundStyle(.secondary)

            GroupBox("Create or update a snippet") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Trigger phrase", text: $trigger)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Replacement")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $replacement)
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .padding(5)

                            if replacement.isEmpty {
                                Text("Enter the text to insert. Press Return for a new line.")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(minHeight: 92, idealHeight: 110, maxHeight: 150)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator, lineWidth: 1)
                        }
                        .accessibilityLabel("Replacement text")
                    }

                    if !replacement.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("Preview")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(lineCount == 1 ? "1 line" : "\(lineCount) lines")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }

                            ScrollView {
                                Text(verbatim: replacement)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(10)
                            }
                            .frame(maxHeight: 110)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    HStack {
                        Text("Use the same trigger again to update its replacement.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save Snippet", action: add)
                            .keyboardShortcut(.return, modifiers: [.command])
                            .disabled(!canSave)
                    }
                }
                .padding(.top, 4)
            }

            List(store.snippets) { snippet in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snippet.trigger)
                            .fontWeight(.semibold)
                        Text(verbatim: snippet.replacement)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button(role: .destructive) {
                        Task { await store.delete(snippet) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete snippet")
                }
                .padding(.vertical, 3)
            }
            .overlay {
                if store.snippets.isEmpty {
                    ContentUnavailableView(
                        "No snippets yet",
                        systemImage: "text.badge.plus",
                        description: Text("Add a trigger phrase and the text it should insert."))
                }
            }

            if let message = store.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding()
        .navigationTitle("Snippets")
        .task { await store.reload() }
    }

    private var lineCount: Int {
        replacement.components(separatedBy: .newlines).count
    }

    private func add() {
        let savedTrigger = trigger
        let savedReplacement = replacement
        trigger = ""
        replacement = ""
        Task {
            await store.add(trigger: savedTrigger, replacement: savedReplacement)
        }
    }
}
