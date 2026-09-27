import Foundation
import TermindDomain

@MainActor
public protocol NotificationPreferencesPersisting: AnyObject {
    func loadNotificationPreferences() throws -> NotificationPreferences
    func saveNotificationPreferences(_ value: NotificationPreferences) throws
}
