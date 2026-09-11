import Foundation
import SwiftData
import TermindDomain

/// The V1–V9 shape stays frozen so adding lifecycle fields does not rewrite the
/// checksums of schemas already shipped to users.
public enum TermindSchemaV9Models {
    @Model
    public final class PersistentCommandHistoryEntry {
        @Attribute(.unique) public var id: UUID = UUID()
        public var hostID: UUID = UUID()
        public var command = ""
        public var executedAt = Date(timeIntervalSince1970: 0)

        public init(_ value: CommandHistoryEntry) {
            id = value.id
            hostID = value.hostID
            command = value.command
            executedAt = value.executedAt
        }
    }
}

@Model
public final class PersistentCommandHistoryEntry {
    @Attribute(.unique) public var id: UUID = UUID()
    public var hostID: UUID = UUID()
    public var command = ""
    public var executedAt = Date(timeIntervalSince1970: 0)
    public var exitStatus: Int32?
    public var duration: TimeInterval?

    public init(_ value: CommandHistoryEntry) {
        apply(value)
    }

    public func apply(_ value: CommandHistoryEntry) {
        id = value.id
        hostID = value.hostID
        command = value.command
        executedAt = value.executedAt
        exitStatus = value.exitStatus
        duration = value.duration
    }

    public var value: CommandHistoryEntry {
        CommandHistoryEntry(
            id: id, hostID: hostID, command: command, executedAt: executedAt,
            exitStatus: exitStatus, duration: duration
        )
    }
}
