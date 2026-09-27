import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentNotificationPreferences {
    @Attribute(.unique) public var key = "default"
    public var data = Data()

    public init(_ value: NotificationPreferences) throws { try apply(value) }
    public func load() throws -> NotificationPreferences {
        try JSONDecoder().decode(NotificationPreferences.self, from: data)
    }
    public func apply(_ value: NotificationPreferences) throws { data = try JSONEncoder().encode(value) }
}
