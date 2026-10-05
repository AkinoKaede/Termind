import Foundation
import SwiftData

/// The V1–V9 shape stays frozen so adding lifecycle fields does not rewrite the
/// checksums of schemas already shipped to users.
public enum TermindSchemaV9Models {
    @Model
    public final class PersistentCommandHistoryEntry {
        @Attribute(.unique) public var id: UUID = UUID()
        public var hostID: UUID = UUID()
        public var command = ""
        public var executedAt = Date(timeIntervalSince1970: 0)

        public init(hostID: UUID, command: String, executedAt: Date) {
            self.hostID = hostID
            self.command = command
            self.executedAt = executedAt
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

    public init(hostID: UUID, command: String, executedAt: Date) {
        self.hostID = hostID
        self.command = command
        self.executedAt = executedAt
    }
}
