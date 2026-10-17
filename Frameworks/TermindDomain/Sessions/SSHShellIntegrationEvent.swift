import Foundation

public nonisolated enum SSHShellIntegrationEvent: Sendable {
    case runtime(TerminalRuntimeUpdate)
    /// Ordinary PTY startup completed without hooks; this grants no runtime context capabilities.
    case ordinaryStartupUnavailable(ticket: SSHOrdinaryStartupTicket?)
    case available(shell: String, systemInfo: RemoteSystemInfo?, homeDirectory: String?)
    case systemInfo(RemoteSystemInfo)
    case homeResolutionUnavailable
    case promptReady
    case commandStarted(String)
    case commandFinished(Int32, duration: TimeInterval?)
    case draft(String)
}

/// A single connection/input epoch, revalidated by the transport before fallback submission.
public nonisolated struct SSHOrdinaryStartupTicket: Sendable, Equatable {
    public let generation: UUID
    public let inputRevision: UInt64

    public init(generation: UUID, inputRevision: UInt64) {
        self.generation = generation
        self.inputRevision = inputRevision
    }
}
