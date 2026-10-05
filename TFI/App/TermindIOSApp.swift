import SwiftUI
import TermindApplication

@main
struct TermindIOSApp: App {
    static let mainWindowID = "main"

    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    private let startup: Result<MobileAppModel, any Error>

    init() {
        MobileLanguagePreferenceMigration.run()
        startup = Result {
            let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            return try MobileAppModel(dependencies: isTesting ? .testing() : .live())
        }
        appDelegate.app = try? startup.get()
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID, makeContent: MobileStartupView.sceneContent(for: startup))
            .commands { MobileCommands() }
    }
}
