import Foundation
import TermindDomain

/// A group-bound dialer. Failed Tailnet connections never retry through the system network.
public nonisolated protocol SSHNetworkDialing: Sendable {
    func open(host: String, port: Int, timeout: TimeInterval) async throws -> Int32
    func hostKeys(stableNodeID: String) async throws -> Set<SSHHostKeyIdentity>
}

@MainActor
public protocol TailscaleConnectionProviding: AnyObject {
    func connection(for groupID: UUID) throws -> any SSHNetworkDialing
}

public nonisolated struct TailscaleLocalState: Sendable {
    public var groupID: UUID
    public var profileID: UUID
    public var peers: [TailscalePeer]
    public var hostname: String?
    public init(groupID: UUID, profileID: UUID, peers: [TailscalePeer] = [], hostname: String? = nil) {
        self.groupID = groupID
        self.profileID = profileID
        self.peers = peers
        self.hostname = hostname
    }
}

@MainActor
public protocol TailscaleLocalStoring: AnyObject {
    func load() throws -> [TailscaleLocalState]
    func save(_ state: TailscaleLocalState) throws
    func remove(groupID: UUID) throws
}

@MainActor
public final class InMemoryTailscaleLocalStore: TailscaleLocalStoring {
    private var states: [UUID: TailscaleLocalState] = [:]
    public init() {}
    public func load() throws -> [TailscaleLocalState] { Array(states.values) }
    public func save(_ state: TailscaleLocalState) throws { states[state.groupID] = state }
    public func remove(groupID: UUID) throws { states[groupID] = nil }
}
