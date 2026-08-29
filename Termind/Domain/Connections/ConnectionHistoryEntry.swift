import Foundation

/// One user-initiated connection to a saved Host.
///
/// Every attempt is retained as its own event so the History sidebar can show
/// repeated visits to the same destination.
nonisolated struct ConnectionHistoryEntry: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: String, Hashable, Sendable {
        case ssh
        case sftp

        var label: String {
            switch self {
            case .ssh: String(localized: "SSH")
            case .sftp: String(localized: "SFTP")
            }
        }

        var symbol: String {
            switch self {
            case .ssh: "terminal"
            case .sftp: "folder"
            }
        }
    }

    var id: UUID = UUID()
    var hostID: Host.ID
    var kind: Kind
    var connectedAt: Date = Date()
}
