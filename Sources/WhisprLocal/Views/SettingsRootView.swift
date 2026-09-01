import SwiftUI

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case general
    case intelligence
    case testLab
    case history
    case dictionary
    case snippets
    case advanced
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .intelligence: "Intelligence"
        case .testLab: "Test Lab"
        case .history: "History"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .intelligence: "sparkles"
        case .testLab: "testtube.2"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "text.book.closed"
        case .snippets: "text.badge.plus"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }
}

struct SettingsRootView: View {
    @Bindable var environment: AppEnvironment
    @State private var selection: SettingsDestination? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsDestination.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
        } detail: {
            destinationView(selection ?? .general)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .alert(
            "WhisprLocal notice",
            isPresented: Binding(
                get: { environment.coordinator.warningMessage != nil },
                set: { if !$0 { environment.coordinator.warningMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                environment.coordinator.warningMessage = nil
            }
        } message: {
            Text(environment.coordinator.warningMessage ?? "")
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .general:
            GeneralSettingsView(environment: environment)
        case .intelligence:
            IntelligenceSettingsView(environment: environment)
        case .testLab:
            TestLabView(environment: environment)
        case .history:
            HistoryView(
                store: environment.historyStore,
                dictionaryStore: environment.dictionaryStore
            )
        case .dictionary:
            DictionaryView(
                store: environment.dictionaryStore,
                preferences: environment.preferences
            )
        case .snippets:
            SnippetsView(store: environment.snippetStore)
        case .advanced:
            AdvancedSettingsView(environment: environment)
        case .about:
            AboutView()
        }
    }
}
