import SwiftData
import SwiftUI
import TermindApplication

@main
struct TermindIOSApp: App {
    @UIApplicationDelegateAdaptor(MobileCloudNotifications.self) private var notifications
    @AppStorage("mobile.appearance") private var appearance = "system"
    private let launchLanguage = AppLanguage.stored()
    private let startup: Result<MobileAppModel, any Error>

    init() {
        startup = Result {
            try MobileAppModel(inMemory: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            switch startup {
            case .success(let app):
                MobileRootView(app: app)
                    .modelContainer(app.container)
                    .environment(\.locale, launchLanguage.locale)
                    .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            case .failure:
                ContentUnavailableView(
                    "Unable to Open Termind", systemImage: "exclamationmark.triangle",
                    description: Text("The local data store could not be opened. Please restart the app."))
            }
        }
    }
}
