import SwiftUI
import TermindApplication

struct MobileSettingsView: View {
    let app: MobileAppModel
    var reviewScene: MobileSceneModel? = nil
    @AppStorage(SettingsKey.debugSectionEnabled) private var debugSectionEnabled = false

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
                    MobileConnectionSettingsView(ssh: app.sshSettings, sftp: app.sftpSettings)
                } label: {
                    Label("Connections", systemImage: "network")
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
            if debugSectionEnabled {
                Section {
                    NavigationLink {
                        MobileLoggingView(logging: app.logging)
                    } label: {
                        Label("Logging", systemImage: "doc.text")
                    }
                    LabeledContent {
                        Text(verbatim: DeviceCensorship.canDisplayTaiwanFlag ? "true" : "false")
                    } label: {
                        Label("Taiwan Flag Available", systemImage: "touchid")
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .mobileReviewPage("settings", scene: reviewScene)
    }
}
