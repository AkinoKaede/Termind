import Foundation
import UIKit

/// Links keep their existing workspace UUID. Window ownership is resolved locally by the app.
@MainActor
enum MobileWorkspaceSceneRouting {
    nonisolated enum CloseError: Error {
        case sessionNotFound
    }

    static let activityType = "com.akinokaede.termind.open-workspace"
    static let closedWindowActivityType = "com.akinokaede.termind.reopen-window"
    private static let workspaceIDKey = "workspaceID"

    static func openSessionIDs() -> Set<String> {
        Set(
            UIApplication.shared.openSessions
                .filter { $0.role == .windowApplication }
                .map(\.persistentIdentifier))
    }

    static func activity(for workspaceID: UUID) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        activity.userInfo = [workspaceIDKey: workspaceID.uuidString]
        return activity
    }

    static func workspaceID(from activity: NSUserActivity) -> UUID? {
        guard activity.activityType == activityType,
            let value = activity.userInfo?[workspaceIDKey] as? String
        else { return nil }
        return UUID(uuidString: value)
    }

    static func createWindow(_ recordID: UUID, failed: @escaping @MainActor () -> Void) {
        let activity = NSUserActivity(activityType: closedWindowActivityType)
        activity.userInfo = ["closedRecordID": recordID.uuidString]
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: nil) { _ in
            MainActor.assumeIsolated { failed() }
        }
    }

    static func closedRecordID(from activity: NSUserActivity) -> UUID? {
        guard activity.activityType == closedWindowActivityType,
            let value = activity.userInfo?["closedRecordID"] as? String
        else { return nil }
        return UUID(uuidString: value)
    }

    static func reconcile(app: MobileAppModel, activeSessionID: String?) {
        app.reconcileWorkspaceSessions(
            openSessionIDs: Set(UIApplication.shared.openSessions.map(\.persistentIdentifier)),
            activeSessionID: activeSessionID)
    }

    static func activate(sessionID: String, workspaceID: UUID, unavailable: @escaping @MainActor () -> Void) {
        guard let session = UIApplication.shared.openSessions.first(where: { $0.persistentIdentifier == sessionID })
        else {
            unavailable()
            return
        }
        UIApplication.shared.requestSceneSessionActivation(
            session, userActivity: activity(for: workspaceID), options: nil
        ) { _ in
            MainActor.assumeIsolated { unavailable() }
        }
    }

    static func close(sessionID: String, failed: @escaping @MainActor (any Error) -> Void) {
        guard let session = UIApplication.shared.openSessions.first(where: { $0.persistentIdentifier == sessionID })
        else {
            failed(CloseError.sessionNotFound)
            return
        }
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { error in
            MainActor.assumeIsolated { failed(error) }
        }
    }
}
