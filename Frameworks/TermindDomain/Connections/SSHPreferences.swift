import Foundation

/// The client-side ceiling for OpenSSH-style sessions on one SSH connection.
public nonisolated struct SSHPreferences: Codable, Hashable, Sendable {
    public static let defaultMaxSessions = 10
    public static let maxSessionsRange = 1...100

    public var maxSessions: Int

    public init(maxSessions: Int = defaultMaxSessions) {
        self.maxSessions = min(
            max(maxSessions, Self.maxSessionsRange.lowerBound),
            Self.maxSessionsRange.upperBound)
    }

    public var normalized: Self { Self(maxSessions: maxSessions) }

    /// Remote values are validated rather than clamped before entering the sync journal.
    public var isValid: Bool { Self.maxSessionsRange.contains(maxSessions) }
}
