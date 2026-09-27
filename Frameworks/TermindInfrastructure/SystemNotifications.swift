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
    private let center: UNUserNotificationCenter?
    private var desiredBadgeCount = 0
    private var badgeTask: Task<Void, Never>?

    public override init() {
        center =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
        setBadgeCount(0)
    }

    public func authorization(request: Bool = false) async -> NotificationAuthorization {
        guard let center else { return .denied }
        var status = await center.notificationSettings().authorizationStatus
        if request, status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            status = await center.notificationSettings().authorizationStatus
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

    private nonisolated static func target(_ content: UNNotificationContent) -> NotificationTarget? {
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
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let target = Self.target(response.notification.request.content)
        else { return }
        let identifier = response.notification.request.identifier
        await MainActor.run {
            remove([identifier])
            if let onOpen { onOpen(target) } else { pendingTarget = target }
        }
    }
}
