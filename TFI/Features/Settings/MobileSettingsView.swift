import SwiftUI

struct MobileSettingsView: View {
    let app: MobileAppModel
    var reviewScene: MobileSceneModel? = nil

    var body: some View {
        Form {
            Section {
                Button("Termind Pro", systemImage: "sparkles.rectangle.stack") { app.pro.presentPaywall() }
            }
            Section {
                NavigationLink {
                    MobileAppSettingsView(appReview: app.appReview, reviewScene: reviewScene)
                } label: {
                    Label("App", systemImage: "app.badge")
                }
                NavigationLink {
                    MobileTerminalSettingsView(model: app.terminalSettings)
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                NavigationLink {
                    MobileSFTPSettingsView(model: app.sftpSettings)
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
        }
        .navigationTitle("Settings")
        .mobileReviewPage("settings", scene: reviewScene)
    }
}
