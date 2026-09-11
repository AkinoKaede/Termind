import SwiftUI

struct MobileSettingsView: View {
    let app: MobileAppModel
    var body: some View {
        Form {
            Section { Button("Termind Pro") { app.pro.presentPaywall() } }
            Section {
                NavigationLink("App") { MobileAppSettingsView() }
                NavigationLink("Terminal") { MobileTerminalSettingsView(model: app.terminalSettings) }
                NavigationLink("AI") { MobileAISettingsView(ai: app.ai) }
                NavigationLink("Sync") { MobileSyncSettingsView(app: app) }
            }
        }.navigationTitle("Settings")
    }
}
