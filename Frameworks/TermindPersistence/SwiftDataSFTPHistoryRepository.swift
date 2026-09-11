import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentSFTPHistoryEntry {
    @Attribute(.unique) public var id: UUID = UUID()
    public var hostID: UUID = UUID()
    public var kind = SFTPHistoryEntry.Kind.directory.rawValue
    public var path = "/"
    public var visitedAt = Date(timeIntervalSince1970: 0)

    public init(_ value: SFTPHistoryEntry) {
        id = value.id
        hostID = value.hostID
        kind = value.kind.rawValue
        path = value.path
        visitedAt = value.visitedAt
    }

    public var value: SFTPHistoryEntry {
        SFTPHistoryEntry(
            id: id, hostID: hostID,
            kind: SFTPHistoryEntry.Kind(rawValue: kind) ?? .directory,
            path: path, visitedAt: visitedAt
        )
    }
}
