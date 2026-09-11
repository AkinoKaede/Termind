import SwiftData
import SwiftUI

@main
struct TermindIOSApp: App {
    @AppStorage("mobile.appearance") private var appearance = "system"
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
                    .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            case .failure:
                ContentUnavailableView(
                    "Unable to Open Termind", systemImage: "exclamationmark.triangle",
                    description: Text("The local data store could not be opened. Please restart the app."))
            }
        }
    }
}
