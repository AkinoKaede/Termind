import Foundation

/// One command the remote shell confirmed it was about to execute.
///
/// History is deliberately its own entity rather than a field on `Host`: a
/// busy terminal can append frequently without rewriting host configuration.
nonisolated struct CommandHistoryEntry: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var hostID: Host.ID
    var command: String
    var executedAt: Date = Date()
}
