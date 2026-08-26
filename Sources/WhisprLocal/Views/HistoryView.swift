import SwiftUI

struct HistoryView: View {
    @Bindable var store: HistoryStore
    let dictionaryStore: DictionaryStore
    @State private var selection: Int64?

    var body: some View {
        HSplitView {
            List(store.records, selection: $selection) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.correctedText)
                        .lineLimit(2)
                    Text(record.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(record.id)
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        Task { await store.delete(record) }
                    }
                }
            }
            .frame(minWidth: 230)

            if let record = selectedRecord {
                HistoryDetailView(record: record, dictionaryStore: dictionaryStore)
                    .frame(minWidth: 360)
            } else {
                ContentUnavailableView(
                    "No transcription selected",
                    systemImage: "text.bubble"
                )
            }
        }
        .task {
            await store.reload()
            selection = selection ?? store.records.first?.id
        }
    }

    private var selectedRecord: TranscriptionRecord? {
        store.records.first { $0.id == selection }
    }
}

private struct HistoryDetailView: View {
    let record: TranscriptionRecord
    let dictionaryStore: DictionaryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                diffText
                    .textSelection(.enabled)

                GroupBox("Raw transcript") {
                    Text(record.rawText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                let candidates = CorrectionAnalyzer.candidates(
                    raw: record.rawText,
                    corrected: record.correctedText
                )
                if !candidates.isEmpty {
                    GroupBox("Teach WhisprLocal") {
                        VStack(alignment: .leading) {
                            Text("Review these suggestions. Nothing is learned until you choose Teach.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(candidates) { candidate in
                                HStack {
                                    Text("\(candidate.original) → \(candidate.replacement)")
                                    Spacer()
                                    Button("Teach") {
                                        Task {
                                            await dictionaryStore.teach(
                                                canonicalTerm: candidate.replacement,
                                                spokenAlias: candidate.original
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                LabeledContent("Engine", value: record.transcriptionEngine)
                LabeledContent("Cleanup", value: record.cleanupEngine)
                LabeledContent(
                    "Latency",
                    value: record.processingLatency.formatted(.number.precision(.fractionLength(2))) + " s"
                )
            }
            .padding()
        }
    }

    private var diffText: Text {
        CorrectionAnalyzer.diff(raw: record.rawText, corrected: record.correctedText)
            .reduce(Text("")) { result, item in
                let value = Text(item.text + " ")
                switch item.kind {
                case .unchanged:
                    return Text("\(result)\(value)")
                case .removed:
                    return Text("\(result)\(value.foregroundStyle(.red).strikethrough())")
                case .inserted:
                    return Text("\(result)\(value.foregroundStyle(.green).bold())")
                }
            }
    }
}
