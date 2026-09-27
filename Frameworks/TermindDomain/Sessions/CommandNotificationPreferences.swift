import Foundation

public nonisolated struct CommandNotificationPreferences: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case never, unfocused, always
    }

    public var mode: Mode = .never
    public var notify = true
    public var bell = false
    public var after: TimeInterval = 5

    public init() {}

    public var threshold: TimeInterval { after.isFinite && after >= 0 ? after : 5 }
}
