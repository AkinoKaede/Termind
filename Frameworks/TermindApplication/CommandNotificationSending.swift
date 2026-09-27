import Foundation

public nonisolated enum CommandNotificationAuthorization: Sendable {
    case notDetermined, allowed, denied
}

@MainActor
public protocol CommandNotificationSending: AnyObject {
    func authorization(request: Bool) async -> CommandNotificationAuthorization
    func send(sessionID: UUID, title: String, body: String) async
}
