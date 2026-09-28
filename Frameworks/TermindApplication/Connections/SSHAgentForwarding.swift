import Foundation

/// A connection-scoped capability. No private material crosses the SSH protocol.
public nonisolated struct SSHAgentIdentity: Sendable, Equatable {
    public let blob: Data
    public let comment: String
    public init(blob: Data, comment: String) {
        self.blob = blob
        self.comment = comment
    }
}

public nonisolated protocol SSHAgentForwarding: Sendable {
    @MainActor func identities() async throws -> [SSHAgentIdentity]
    /// Returns the SSH signature blob (algorithm string and signature string).
    @MainActor func sign(key: Data, data: Data, flags: UInt32) async throws -> Data
    @MainActor func close() async
}

public typealias SSHAgentForwardingFactory = @Sendable (SSHConnectionRequest) async throws -> (any SSHAgentForwarding)?

public struct SSHAgentInteractionContext: Sendable {
    public let unlock: SSHKeyboardInteractiveHandler?
    public let securityKeySigning: SecurityKeySigningHandler?
    public let canInteract: @MainActor @Sendable () -> Bool
    public init(
        unlock: SSHKeyboardInteractiveHandler? = nil, securityKeySigning: SecurityKeySigningHandler? = nil,
        canInteract: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.unlock = unlock
        self.securityKeySigning = securityKeySigning
        self.canInteract = canInteract
    }
}
