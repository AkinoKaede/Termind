import UIKit

@MainActor
final class MobileAppDelegate: UIResponder, UIApplicationDelegate {
    weak var app: MobileAppModel? {
        didSet {
            guard let app else { return }
            app.discardWorkspaceSessions(pendingDiscardedSessionIDs)
            pendingDiscardedSessionIDs.removeAll()
        }
    }
    private var pendingDiscardedSessionIDs: Set<String> = []

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        MobileHistoryMenuConfiguration.apply(to: builder)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        app?.clearNotificationBadge()
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        discardSessions(Set(sceneSessions.map(\.persistentIdentifier)))
    }

    func discardSessions(_ ids: Set<String>) {
        if let app {
            app.discardWorkspaceSessions(ids)
        } else {
            pendingDiscardedSessionIDs.formUnion(ids)
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = MobileSceneDelegate.self
        }
        return configuration
    }
}
