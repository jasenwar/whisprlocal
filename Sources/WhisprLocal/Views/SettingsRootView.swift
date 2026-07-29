import SwiftUI

struct SettingsRootView: View {
    @Bindable var environment: AppEnvironment

    var body: some View {
        TabView {
            GeneralSettingsView(environment: environment)
                .tabItem { Label("General", systemImage: "gearshape") }
            HistoryView(
                store: environment.historyStore,
                dictionaryStore: environment.dictionaryStore
            )
            .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            DictionaryView(store: environment.dictionaryStore)
                .tabItem { Label("Dictionary", systemImage: "text.book.closed") }
            SnippetsView(store: environment.snippetStore)
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(14)
        .alert(
            "Raw transcript used",
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
}
