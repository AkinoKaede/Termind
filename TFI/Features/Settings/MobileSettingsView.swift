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
                Button(AppStrings.Pro.termindPro.swiftUIKey, systemImage: "sparkles.rectangle.stack") {
                    app.pro.presentPaywall()
                }
            }
            Section {
                NavigationLink {
                    MobileAppSettingsView(
                        workspaceSettings: app.workspaceSettings,
                        appReview: app.appReview,
                        reviewScene: reviewScene,
                        diagnosis: app.diagnosis)
                } label: {
                    Label(AppStrings.Settings.app.swiftUIKey, systemImage: "app.badge")
                }
                NavigationLink {
                    Form {
                        NotificationSettingsFields(
                            model: app.notificationSettings, service: app.notifications,
                            openSettings: TerminalNotificationPlatform.openSettings)
                    }
                    .navigationTitle(AppStrings.Notifications.title)
                } label: {
                    Label(AppStrings.Notifications.title, systemImage: "bell.badge")
                }
                NavigationLink {
                    MobileTerminalSettingsView(model: app.terminalSettings)
                } label: {
                    Label(AppStrings.Settings.terminal.swiftUIKey, systemImage: "terminal")
                }
                NavigationLink {
                    MobileConnectionSettingsView(ssh: app.sshSettings, sftp: app.sftpSettings)
                } label: {
                    Label(AppStrings.Settings.connections.swiftUIKey, systemImage: "network")
                }
                NavigationLink {
                    MobileAISettingsView(app: app)
                } label: {
                    Label(AppStrings.Settings.ai.swiftUIKey, systemImage: "sparkles")
                }
                NavigationLink {
                    MobileSyncSettingsView(app: app)
                } label: {
                    Label(AppStrings.Settings.sync.swiftUIKey, systemImage: "icloud")
                }
            }
            if debugSectionEnabled {
                Section {
                    NavigationLink {
                        MobileLoggingView(logging: app.logging)
                    } label: {
                        Label(AppStrings.Settings.logging.swiftUIKey, systemImage: "doc.text")
                    }
                    LabeledContent {
                        Text(verbatim: String(DeviceCensorship.canDisplayTaiwanFlag))
                    } label: {
                        Label(AppStrings.Settings.taiwanFlagAvailable.swiftUIKey, systemImage: "touchid")
                    }
                }
            }
        }
        .navigationTitle(AppStrings.Navigation.settings.swiftUIKey)
        .mobileReviewPage("settings", scene: reviewScene)
    }
}
