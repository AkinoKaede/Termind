import Combine
import Foundation
import TermindApplication
import TermindDomain
import UIKit

nonisolated enum MobileHomeScreenQuickAction: Equatable, Sendable {
    case connect
    case history(hostID: Host.ID)
}

struct MobileHomeScreenQuickActionDescriptor: Equatable {
    let action: MobileHomeScreenQuickAction
    let title: String
    let symbol: String

    var shortcutItem: UIApplicationShortcutItem {
        let userInfo: [String: any NSSecureCoding]?
        switch action {
        case .connect:
            userInfo = nil
        case .history(let hostID):
            userInfo = [
                MobileHomeScreenQuickActions.hostIDKey: hostID.uuidString as NSString
            ]
        }
        return UIApplicationShortcutItem(
            type: MobileHomeScreenQuickActions.type(for: action),
            localizedTitle: title,
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: symbol),
            userInfo: userInfo
        )
    }
}

@MainActor
enum MobileHomeScreenQuickActions {
    static let historyLimit = 3
    static let connectType = "com.akinokaede.termind.quickAction.connect"
    static let historyType = "com.akinokaede.termind.quickAction.history"
    static let hostIDKey = "hostID"
    /// Retained only so shortcuts emitted by an earlier build still decode.
    static let kindKey = "kind"

    static func type(for action: MobileHomeScreenQuickAction) -> String {
        switch action {
        case .connect: connectType
        case .history: historyType
        }
    }

    static func action(from shortcutItem: UIApplicationShortcutItem) -> MobileHomeScreenQuickAction? {
        switch shortcutItem.type {
        case connectType:
            return .connect
        case historyType:
            guard
                let hostIDValue = shortcutItem.userInfo?[hostIDKey] as? NSString,
                let hostID = UUID(uuidString: hostIDValue as String)
            else { return nil }
            return .history(hostID: hostID)
        default:
            return nil
        }
    }

    static func descriptors(rows: [MobileRecentHostRow]) -> [MobileHomeScreenQuickActionDescriptor] {
        rows.lazy.filter(\.canOpen).prefix(historyLimit).map { row in
            return MobileHomeScreenQuickActionDescriptor(
                action: .history(hostID: row.host.id),
                title: row.host.name,
                symbol: "server.rack"
            )
        }
    }

    static func refresh(app: MobileAppModel) {
        let rows = MobileConnectionHistory.recentHostRows(
            history: app.connectionHistory,
            library: app.library,
            limit: ConnectionHistoryModel.limit
        )
        UIApplication.shared.shortcutItems = descriptors(rows: rows).map(\.shortcutItem)
    }
}

@MainActor
final class MobileSceneDelegate: NSObject, UIWindowSceneDelegate, ObservableObject {
    @Published private(set) var sessionID: String?
    @Published private(set) var pendingWorkspaceID: UUID?
    private(set) weak var app: MobileAppModel?
    @Published private(set) var pendingQuickAction: MobileHomeScreenQuickAction?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        sessionID = session.persistentIdentifier
        for activity in connectionOptions.userActivities { receiveWorkspaceActivity(activity) }
        guard let shortcutItem = connectionOptions.shortcutItem else { return }
        _ = receive(shortcutItem)
    }

    func bind(to app: MobileAppModel) {
        self.app = app
        reconcileWindowOwnership()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        reconcileWindowOwnership(activeSessionID: scene.session.persistentIdentifier)
    }

    private func reconcileWindowOwnership(activeSessionID: String? = nil) {
        let application = UIApplication.shared
        let activeID =
            activeSessionID
            ?? application.connectedScenes.first {
                $0.activationState == .foregroundActive
            }?.session.persistentIdentifier
        if let app { MobileWorkspaceSceneRouting.reconcile(app: app, activeSessionID: activeID) }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        receiveWorkspaceActivity(userActivity)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        app?.disconnectWorkspaceScene(scene.session.persistentIdentifier)
        reconcileWindowOwnership()
    }

    func receiveWorkspaceActivity(_ activity: NSUserActivity) {
        guard let id = MobileWorkspaceSceneRouting.workspaceID(from: activity) else { return }
        pendingWorkspaceID = id
    }

    func consumePendingWorkspaceID() -> UUID? {
        defer { pendingWorkspaceID = nil }
        return pendingWorkspaceID
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem
    ) async -> Bool {
        receive(shortcutItem)
    }

    @discardableResult
    func receive(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard let action = MobileHomeScreenQuickActions.action(from: shortcutItem) else { return false }
        pendingQuickAction = action
        return true
    }

    func consumePendingQuickAction() -> MobileHomeScreenQuickAction? {
        defer { pendingQuickAction = nil }
        return pendingQuickAction
    }
}
