import SwiftUI

struct MobileSettingsView: View {
    let app: MobileAppModel
    @AppStorage("mobile.appearance") private var appearance = "system"

    var body: some View {
        Form {
            Section { Button("Termind Pro") { app.pro.presentPaywall() } }
            Section { NavigationLink("AI") { MobileAISettingsView(ai: app.ai) } }
            Section("App") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                LabeledContent(
                    "Version",
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
            }
            Section("Live Activities") {
                Button("Show Workspace Live Activity") { app.liveActivities.start(app.workspaces) }
                Text(
                    "One Live Activity summarizes all workspaces. Tap it to open the workspace list. Live Activities do not keep SSH running in the background."
                )
                .font(.caption).foregroundStyle(.secondary)
                if let error = app.liveActivities.error { Text(error).foregroundStyle(.red) }
            }
        }.navigationTitle("Settings")
    }
}
