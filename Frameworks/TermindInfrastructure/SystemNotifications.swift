import Foundation
import TermindApplication
import UserNotifications

@MainActor
public final class SystemNotifications: NSObject, NotificationSending, UNUserNotificationCenterDelegate {
    public var onOpen: ((NotificationTarget) -> Void)? {
        didSet {
            if let pendingTarget, let onOpen {
                self.pendingTarget = nil
                onOpen(pendingTarget)
            }
        }
    }
    private var pendingTarget: NotificationTarget?
    private let center: (any UserNotificationCenterClient)?
    private var desiredBadgeCount = 0
    private var badgeTask: Task<Void, Never>?

    public override convenience init() {
        self.init(
            center: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
                ? NativeUserNotificationCenter() : nil)
    }

    init(center: (any UserNotificationCenterClient)?) {
        self.center = center
        super.init()
        center?.delegate = self
        setBadgeCount(0)
    }

    public func authorization(request: Bool = false) async -> NotificationAuthorization {
        guard let center else { return .denied }
        var status = await center.authorizationStatus()
        if request, status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            status = await center.authorizationStatus()
        }
        switch status {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    public func send(_ notification: AppNotification, ifCurrent: @escaping @MainActor () -> Bool) async {
        guard let center, await authorization() == .allowed,
            !Task.isCancelled, ifCurrent()
        else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = [
            "targetKind": notification.target.kind, "targetID": notification.target.id?.uuidString ?? "",
        ]
        content.threadIdentifier = "\(notification.target.kind).\(notification.target.id?.uuidString ?? "all")"
        try? await center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
        // Answering a prompt or changing settings can race notification-center delivery.
        if Task.isCancelled || !ifCurrent() { remove([notification.id]) }
    }

    public func remove(_ identifiers: [String]) {
        center?.removePendingNotificationRequests(withIdentifiers: identifiers)
        center?.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    public func setBadgeCount(_ count: Int) {
        desiredBadgeCount = max(0, count)
        guard let center, badgeTask == nil else { return }
        badgeTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                let current = desiredBadgeCount
                try? await center.setBadgeCount(current)
                if desiredBadgeCount == current { break }
            } while !Task.isCancelled
            badgeTask = nil
        }
    }

    nonisolated static func target(_ content: UNNotificationContent) -> NotificationTarget? {
        guard let kind = content.userInfo["targetKind"] as? String,
            let id = content.userInfo["targetID"] as? String
        else { return nil }
        return NotificationTarget(kind: kind, id: id)
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.target(notification.request.content) == nil ? [] : [.banner, .list, .sound]
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        receiveResponse(
            action: response.actionIdentifier,
            identifier: response.notification.request.identifier,
            target: Self.target(response.notification.request.content),
            completionHandler: completionHandler)
    }

    nonisolated func receiveResponse(
        action: String, identifier: String, target: NotificationTarget?,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        // The async delegate bridge can invoke UIKit's completion on a cooperative thread after the actor hop.
        // UIKit may update the scene snapshot there, so complete explicitly on MainActor after routing the click.
        Task { @MainActor in
            receiveResponse(action: action, identifier: identifier, target: target)
            completionHandler()
        }
    }

    func receiveResponse(action: String, identifier: String, target: NotificationTarget?) {
        guard action == UNNotificationDefaultActionIdentifier, let target else { return }
        remove([identifier])
        if let onOpen { onOpen(target) } else { pendingTarget = target }
    }
}

/// A narrow seam for exercising delivery races without accessing the user's notification center.
@MainActor
protocol UserNotificationCenterClient: AnyObject {
    var delegate: (any UNUserNotificationCenterDelegate)? { get set }
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func setBadgeCount(_ count: Int) async throws
}

@MainActor
private final class NativeUserNotificationCenter: UserNotificationCenterClient {
    private let center = UNUserNotificationCenter.current()
    var delegate: (any UNUserNotificationCenterDelegate)? {
        get { center.delegate }
        set { center.delegate = newValue }
    }
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    func setBadgeCount(_ count: Int) async throws { try await center.setBadgeCount(count) }
}
