import SwiftData
import SwiftUI
import TermindApplication

@main
struct TermindIOSApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    @AppStorage("mobile.appearance") private var appearance = "system"
    private let startup: Result<MobileAppModel, any Error>

    init() {
        MobileLanguagePreferenceMigration.run()
        startup = Result {
            let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            return try MobileAppModel(dependencies: isTesting ? .testing() : .live())
        }
    }

    var body: some Scene {
        WindowGroup {
            switch startup {
            case .success(let app):
                MobileQuickActionSceneRoot(app: app)
                    .modelContainer(app.container)
                    .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            case .failure:
                ContentUnavailableView(
                    "Unable to Open Termind", systemImage: "exclamationmark.triangle",
                    description: Text("The local data store could not be opened. Please restart the app."))
            }
        }
        .commands { MobileCommands() }
    }
}

private struct MobileQuickActionSceneRoot: View {
    let app: MobileAppModel
    @EnvironmentObject private var sceneDelegate: MobileSceneDelegate

    var body: some View {
        MobileRootView(
            app: app,
            pendingQuickAction: sceneDelegate.pendingQuickAction,
            consumePendingQuickAction: sceneDelegate.consumePendingQuickAction
        )
    }
}
