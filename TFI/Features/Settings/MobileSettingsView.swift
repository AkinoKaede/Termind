import SwiftUI
import TermindApplication
import TermindPresentation

struct MobileSettingsView: View {
    let app: MobileAppModel
    var reviewScene: MobileSceneModel? = nil
    @AppStorage(SettingsKey.debugSectionEnabled) private var debugSectionEnabled = false

    var body: some View {
        Form {
            Section {
                Button(TermindCopy.Pro.termindPro.swiftUIKey, systemImage: "sparkles.rectangle.stack") {
                    app.pro.presentPaywall()
                }
            }
            Section {
                NavigationLink {
                    MobileAppSettingsView(
                        workspaceSettings: app.workspaceSettings,
                        appReview: app.appReview,
                        reviewScene: reviewScene)
                } label: {
                    Label(TermindCopy.Settings.app.swiftUIKey, systemImage: "app.badge")
                }
                NavigationLink {
                    MobileTerminalSettingsView(model: app.terminalSettings)
                } label: {
                    Label(TermindCopy.Settings.terminal.swiftUIKey, systemImage: "terminal")
                }
                NavigationLink {
                    MobileConnectionSettingsView(ssh: app.sshSettings, sftp: app.sftpSettings)
                } label: {
                    Label(TermindCopy.Settings.connections.swiftUIKey, systemImage: "network")
                }
                NavigationLink {
                    MobileAISettingsView(app: app)
                } label: {
                    Label(TermindCopy.Settings.ai.swiftUIKey, systemImage: "sparkles")
                }
                NavigationLink {
                    MobileSyncSettingsView(app: app)
                } label: {
                    Label(TermindCopy.Settings.sync.swiftUIKey, systemImage: "icloud")
                }
            }
            if debugSectionEnabled {
                Section {
                    NavigationLink {
                        MobileLoggingView(logging: app.logging)
                    } label: {
                        Label(TermindCopy.Settings.logging.swiftUIKey, systemImage: "doc.text")
                    }
                    LabeledContent {
                        Text(verbatim: String(DeviceCensorship.canDisplayTaiwanFlag))
                    } label: {
                        Label(TermindCopy.Settings.taiwanFlagAvailable.swiftUIKey, systemImage: "touchid")
                    }
                }
            }
        }
        .navigationTitle(TermindCopy.Navigation.settings.swiftUIKey)
        .mobileReviewPage("settings", scene: reviewScene)
    }
}
