import SwiftData
import SwiftUI

@main
struct TermindIOSApp: App {
    private let startup: Result<MobileAppModel, any Error>

    init() {
        startup = Result { try MobileAppModel() }
    }

    var body: some Scene {
        WindowGroup {
            switch startup {
            case .success(let app):
                MobileRootView(app: app)
                    .modelContainer(app.container)
            case .failure:
                ContentUnavailableView(
                    "Unable to Open Termind", systemImage: "exclamationmark.triangle",
                    description: Text("The local data store could not be opened. Please restart the app."))
            }
        }
    }
}
