import Foundation
import TermindApplication
import UserNotifications

@MainActor
public final class SystemCommandNotifications: NSObject, CommandNotificationSending, UNUserNotificationCenterDelegate {
    public var onOpenSession: ((UUID) -> Void)? {
        didSet {
            if let pendingSession, let onOpenSession {
                self.pendingSession = nil
                onOpenSession(pendingSession)
            }
        }
    }
    private var pendingSession: UUID?
    private let center: UNUserNotificationCenter?

    public override init() {
        center =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
    }

    public func authorization(request: Bool = false) async -> CommandNotificationAuthorization {
        guard let center else { return .denied }
        var status = await center.notificationSettings().authorizationStatus
        if request, status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert])
            status = await center.notificationSettings().authorizationStatus
        }
        switch status {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    public func send(sessionID: UUID, title: String, body: String) async {
        guard let center, await authorization() == .allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["commandSessionID": sessionID.uuidString]
        content.threadIdentifier = sessionID.uuidString
        // Sound is controlled separately by the terminal bell setting.
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.content.userInfo["commandSessionID"] == nil ? [] : [.banner, .list]
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let raw = response.notification.request.content.userInfo["commandSessionID"] as? String,
            let id = UUID(uuidString: raw)
        else { return }
        await MainActor.run {
            if let onOpenSession { onOpenSession(id) } else { pendingSession = id }
        }
    }
}
