import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentConnectionHistoryEntry {
    @Attribute(.unique) public var id: UUID = UUID()
    public var hostID: UUID = UUID()
    public var kind = ConnectionHistoryEntry.Kind.ssh.rawValue
    public var connectedAt = Date(timeIntervalSince1970: 0)

    public init(_ value: ConnectionHistoryEntry) {
        id = value.id
        hostID = value.hostID
        kind = value.kind.rawValue
        connectedAt = value.connectedAt
    }

    public var value: ConnectionHistoryEntry {
        ConnectionHistoryEntry(
            id: id, hostID: hostID,
            kind: ConnectionHistoryEntry.Kind(rawValue: kind) ?? .ssh,
            connectedAt: connectedAt
        )
    }
}
