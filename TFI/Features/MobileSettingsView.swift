import SwiftUI

struct MobileSettingsView: View {
    let app: MobileAppModel
    var body: some View {
        Form {
            Section {
                Button("Termind Pro", systemImage: "sparkles.rectangle.stack") { app.pro.presentPaywall() }
            }
            Section {
                NavigationLink {
                    MobileAppSettingsView()
                } label: {
                    Label("App", systemImage: "app.badge")
                }
                NavigationLink {
                    MobileTerminalSettingsView(model: app.terminalSettings)
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                NavigationLink {
                    MobileSFTPSettingsView(transfers: app.transfers)
                } label: {
                    Label("SFTP", systemImage: "arrow.up.arrow.down")
                }
                NavigationLink {
                    MobileAISettingsView(app: app)
                } label: {
                    Label("AI", systemImage: "sparkles")
                }
                NavigationLink {
                    MobileSyncSettingsView(app: app)
                } label: {
                    Label("Sync", systemImage: "icloud")
                }
            }
        }.navigationTitle("Settings")
    }
}
