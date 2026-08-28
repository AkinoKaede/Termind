import Foundation

/// A remote path the user successfully visited or opened through SFTP.
nonisolated struct SFTPHistoryEntry: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: String, Hashable, Sendable {
        case directory
        case file

        var symbol: String { self == .directory ? "folder.fill" : "doc" }
    }

    var id: UUID = UUID()
    var hostID: Host.ID
    var kind: Kind
    var path: String
    var visitedAt: Date = Date()

    var name: String {
        if path == "/" { return "/" }
        return (path as NSString).lastPathComponent
    }
}
