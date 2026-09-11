import Foundation

/// One command the remote shell confirmed it was about to execute.
///
/// History is deliberately its own entity rather than a field on `Host`: a
/// busy terminal can append frequently without rewriting host configuration.
public nonisolated struct CommandHistoryEntry: Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var hostID: Host.ID
    public var command: String
    public var executedAt: Date = Date()
    /// `nil` means the shell never reported a completion event, including rows
    /// written by versions that predate command lifecycle reporting.
    public var exitStatus: Int32?
    public var duration: TimeInterval?
    public init(
        id: UUID = UUID(), hostID: Host.ID, command: String, executedAt: Date = Date(), exitStatus: Int32? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.command = command
        self.executedAt = executedAt
        self.exitStatus = exitStatus
        self.duration = duration
    }

}
