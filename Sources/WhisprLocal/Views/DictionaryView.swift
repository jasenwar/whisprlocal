import AppKit
import SwiftUI

struct DictionaryView: View {
    @Bindable var store: DictionaryStore
    @State private var term = ""
    @State private var editor: DictionaryEditorDraft?
    @State private var entryPendingDeletion: DictionaryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Personal Vocabulary")
                .font(.title2.weight(.semibold))

            Text("Keep names, products, and specialized words spelled the way you prefer.")
                .foregroundStyle(.secondary)

            HStack {
                TextField("Name or preferred spelling", text: $term)
                    .onSubmit(addSimpleTerm)
                Button("Add", action: addSimpleTerm)
                    .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Add details") {
                    editor = DictionaryEditorDraft()
                }
            }

            List(store.entries) { entry in
                Button {
                    editor = DictionaryEditorDraft(entry: entry)
                } label: {
                    DictionaryEntryRow(entry: entry)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit") { editor = DictionaryEditorDraft(entry: entry) }
                    Button("Delete", role: .destructive) { entryPendingDeletion = entry }
                }
            }
            .overlay {
                if store.entries.isEmpty {
                    ContentUnavailableView(
                        "No vocabulary yet",
                        systemImage: "text.book.closed",
                        description: Text("Add a preferred spelling to get started."))
                }
            }

            if let message = store.errorMessage {
                Text(message).foregroundStyle(.red).font(.caption)
            }
        }
        .padding()
        .sheet(item: $editor) { draft in
            DictionaryEntryEditor(draft: draft) { savedDraft in
                save(savedDraft)
            }
        }
        .confirmationDialog(
            "Delete \(entryPendingDeletion?.canonicalTerm ?? "this entry")?",
            isPresented: Binding(
                get: { entryPendingDeletion != nil },
                set: { if !$0 { entryPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entryPendingDeletion {
                    Task { await store.delete(entryPendingDeletion) }
                }
                entryPendingDeletion = nil
            }
        } message: {
            Text("This removes the preferred spelling and its spoken variants.")
        }
        .task { await store.reload() }
    }

    private func addSimpleTerm() {
        let value = term
        term = ""
        Task { await store.add(value) }
    }

    private func save(_ draft: DictionaryEditorDraft) {
        editor = nil
        Task {
            if let entry = draft.entry {
                await store.update(
                    entry,
                    canonicalTerm: draft.canonicalTerm,
                    spokenAliases: draft.aliases,
                    kind: draft.kind,
                    isPinned: draft.isPinned,
                    isEnabled: draft.isEnabled,
                    appBundleID: draft.appBundleID
                )
            } else {
                await store.add(
                    canonicalTerm: draft.canonicalTerm,
                    spokenAliases: draft.aliases,
                    kind: draft.kind,
                    isPinned: draft.isPinned,
                    isEnabled: draft.isEnabled,
                    appBundleID: draft.appBundleID
                )
            }
        }
    }
}

private struct DictionaryEntryRow: View {
    let entry: DictionaryEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isPinned ? "pin.fill" : entry.kind.symbolName)
                .foregroundStyle(entry.isPinned ? .orange : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.canonicalTerm).fontWeight(.semibold)
                    if !entry.isEnabled {
                        Text("Off")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if !entry.spokenAliases.isEmpty {
                    Text("Also heard as: \(entry.spokenAliases.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(entry.appBundleID == nil ? "Everywhere" : "Specific app")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(entry.isEnabled ? 1 : 0.58)
        .contentShape(Rectangle())
    }
}

private struct DictionaryEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DictionaryEditorDraft
    let onSave: (DictionaryEditorDraft) -> Void

    init(draft: DictionaryEditorDraft, onSave: @escaping (DictionaryEditorDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.entry == nil ? "Add vocabulary" : "Edit vocabulary")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Preferred spelling", text: $draft.canonicalTerm)
                TextField("Spoken variants", text: $draft.spokenVariants)
                    .help("Separate alternatives with commas. For Jasen, an example is: Jason, Jayson.")

                Picker("Type", selection: $draft.kind) {
                    ForEach(DictionaryEntryKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                Toggle("Pin this entry", isOn: $draft.isPinned)
                Toggle("Use this entry", isOn: $draft.isEnabled)

                Picker("Where to use it", selection: $draft.appBundleID) {
                    Text("Everywhere").tag(Optional<String>.none)
                    ForEach(draft.availableApps) { app in
                        Text(app.displayName).tag(Optional(app.bundleID))
                    }
                }
                Text("Everywhere is the usual choice. Choose an open app to use this word only while dictating there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.canonicalTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }
}

private struct DictionaryEditorDraft: Identifiable {
    let id = UUID()
    let entry: DictionaryEntry?
    var canonicalTerm: String
    var spokenVariants: String
    var kind: DictionaryEntryKind
    var isPinned: Bool
    var isEnabled: Bool
    var appBundleID: String?
    let availableApps: [DictionaryScopedApplication]

    init() {
        entry = nil
        canonicalTerm = ""
        spokenVariants = ""
        kind = .general
        isPinned = false
        isEnabled = true
        appBundleID = nil
        availableApps = DictionaryScopedApplication.available(existingBundleID: nil)
    }

    init(entry: DictionaryEntry) {
        self.entry = entry
        canonicalTerm = entry.canonicalTerm
        spokenVariants = entry.spokenAliases.joined(separator: ", ")
        kind = entry.kind
        isPinned = entry.isPinned
        isEnabled = entry.isEnabled
        let selectedBundleID = entry.appBundleID == Bundle.main.bundleIdentifier ? nil : entry.appBundleID
        appBundleID = selectedBundleID
        availableApps = DictionaryScopedApplication.available(existingBundleID: selectedBundleID)
    }

    var aliases: [String] {
        spokenVariants.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map(String.init)
    }
}

private struct DictionaryScopedApplication: Identifiable, Hashable {
    let bundleID: String
    let displayName: String

    var id: String { bundleID }

    static func available(existingBundleID: String?) -> [Self] {
        let currentBundleID = Bundle.main.bundleIdentifier
        var applications: [String: Self] = [:]
        for application in NSWorkspace.shared.runningApplications {
            guard application.activationPolicy == .regular,
                  let bundleID = application.bundleIdentifier,
                  bundleID != currentBundleID else {
                continue
            }
            applications[bundleID] = Self(
                bundleID: bundleID,
                displayName: application.localizedName ?? "An open app"
            )
        }
        if let existingBundleID, applications[existingBundleID] == nil {
            applications[existingBundleID] = Self(
                bundleID: existingBundleID,
                displayName: "Previously selected app"
            )
        }
        return applications.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

private extension DictionaryEntryKind {
    var symbolName: String {
        switch self {
        case .name: "person.text.rectangle"
        case .acronym: "textformat.abc"
        case .product: "shippingbox"
        case .technical: "cpu"
        case .general: "text.word.spacing"
        }
    }
}
