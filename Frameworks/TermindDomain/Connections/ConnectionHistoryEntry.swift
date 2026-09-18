import Foundation

/// One user-initiated connection to a saved Host.
///
/// Every attempt is retained as its own event so the History sidebar can show
/// repeated visits to the same destination.
public nonisolated struct ConnectionHistoryEntry: Identifiable, Hashable, Sendable {
    public nonisolated enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case ssh
        case sftp

        public var label: String {
            switch self {
            case .ssh: String(localized: "SSH")
            case .sftp: String(localized: "SFTP")
            }
        }

        public var symbol: String {
            switch self {
            case .ssh: "terminal"
            case .sftp: "folder"
            }
        }
    }

    public var id: UUID = UUID()
    public var hostID: Host.ID
    public var kind: Kind
    public var connectedAt: Date = Date()
    public init(id: UUID = UUID(), hostID: Host.ID, kind: Kind, connectedAt: Date = Date()) {
        self.id = id
        self.hostID = hostID
        self.kind = kind
        self.connectedAt = connectedAt
    }

}
