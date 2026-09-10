import SwiftUI

struct WebSearchSettings: View {
    @Environment(AppModel.self) private var app
    private var isEnabled: Bool { app.aiConfiguration.webSearch.isEnabled }
    private var usesBuiltIn: Bool { app.aiConfiguration.webSearch.prefersBuiltIn }
    private func binding(_ keyPath: WritableKeyPath<AIWebSearchPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { app.aiConfiguration.webSearch[keyPath: keyPath] },
            set: { value in
                var preferences = app.aiConfiguration.webSearch
                preferences[keyPath: keyPath] = value
                app.aiConfiguration.setWebSearch(preferences)
            })
    }

    var body: some View {
        Section {
            Toggle("Enable Web Search", isOn: binding(\.isEnabled))

            Toggle("Prefer Built-in Web Search", isOn: binding(\.prefersBuiltIn))
                .disabled(!isEnabled)

            Text(
                usesBuiltIn
                    ? String(
                        localized:
                            "Models with provider-native search use it directly. Other models search Google, Bing, DuckDuckGo, and Yahoo from this Mac and read result pages as Markdown."
                    )
                    : String(
                        localized:
                            "Every model searches Google, Bing, DuckDuckGo, and Yahoo from this Mac and reads result pages as Markdown."
                    )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Web Search")
        }

    }
}
