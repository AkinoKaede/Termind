import UIKit

/// CKSyncEngine owns subscription delivery; registering with APNs enables silent cloud notifications.
@MainActor
final class MobileCloudNotifications: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            application.registerForRemoteNotifications()
        }
        return true
    }
}
