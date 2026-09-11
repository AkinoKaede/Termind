import AgentKit
import Foundation

nonisolated struct MCPServerSession: Sendable {
    var id: String
    var runID: UUID
    var secretBroker: SecretBroker
    var protocolVersion: String
    var clientName: String
    var initialized = false
    var isLegacy: Bool
    var legacyContinuation: AsyncStream<Data>.Continuation?
    var lastUsedAt: ContinuousClock.Instant = .now
}
