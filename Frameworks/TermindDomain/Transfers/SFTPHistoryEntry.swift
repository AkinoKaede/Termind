import Foundation

/// A remote path the user successfully visited or opened through SFTP.
public nonisolated struct SFTPHistoryEntry: Identifiable, Hashable, Sendable {
    public nonisolated enum Kind: String, Hashable, Sendable {
        case directory
        case file

        public var symbol: String { self == .directory ? "folder.fill" : "doc" }
    }

    public var id: UUID = UUID()
    public var sessionID: UUID
    public var kind: Kind
    public var path: String
    public var visitedAt: Date = Date()

    public var name: String {
        if path == "/" { return "/" }
        return (path as NSString).lastPathComponent
    }
    public init(id: UUID = UUID(), sessionID: UUID, kind: Kind, path: String, visitedAt: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.path = path
        self.visitedAt = visitedAt
    }

}
