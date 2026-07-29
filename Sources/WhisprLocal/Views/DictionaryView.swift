import SwiftUI

struct DictionaryView: View {
    @Bindable var store: DictionaryStore
    @State private var term = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Name or preferred spelling", text: $term)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            List(store.entries) { entry in
                HStack {
                    Text(entry.term)
                    Spacer()
                    Button(role: .destructive) {
                        Task { await store.delete(entry) }
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
        let value = term
        term = ""
        Task { await store.add(value) }
    }
}
