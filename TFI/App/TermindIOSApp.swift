import SwiftUI
import TermindApplication

@main
struct TermindIOSApp: App {
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
        WindowGroup(makeContent: MobileStartupView.sceneContent(for: startup))
            .commands { MobileCommands() }
    }
}
