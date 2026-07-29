import SwiftUI

struct SnippetsView: View {
    @Bindable var store: SnippetStore
    @State private var trigger = ""
    @State private var replacement = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Trigger phrase", text: $trigger)
                TextField("Replacement", text: $replacement)
                Button("Add", action: add)
                    .disabled(trigger.isEmpty || replacement.isEmpty)
            }
            List(store.snippets) { snippet in
                HStack(alignment: .firstTextBaseline) {
                    Text(snippet.trigger).fontWeight(.semibold)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    Text(snippet.replacement).lineLimit(2)
                    Spacer()
                    Button(role: .destructive) {
                        Task { await store.delete(snippet) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let message = store.errorMessage {
                Text(message).foregroundStyle(.red).font(.caption)
            }
        }
        .padding()
        .task { await store.reload() }
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
