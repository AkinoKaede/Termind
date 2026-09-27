import UIKit

@MainActor
enum MobileNotificationPlatform {
    static func activate(sessionID: String) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            let session = UIApplication.shared.openSessions.first(where: { $0.persistentIdentifier == sessionID })
        else { return }
        UIApplication.shared.requestSceneSessionActivation(session, userActivity: nil, options: nil)
    }
}
