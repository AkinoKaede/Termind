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
    func scheduleCleanup(profileID: UUID) throws
    func pendingCleanupProfiles() throws -> Set<UUID>
    func completeCleanup(profileID: UUID) throws
}

public nonisolated struct TailscaleProfileStorage: Sendable {
    /// Memory-only app compositions must never inspect or erase live device state.
    public static let disabled = Self(profiles: { [] }, erase: { _ in throw TailscaleConfigurationError.unavailable })

    public var profiles: @Sendable () async throws -> Set<UUID>
    public var erase: @Sendable (UUID) async throws -> Void
    public init(
        profiles: @escaping @Sendable () async throws -> Set<UUID>,
        erase: @escaping @Sendable (UUID) async throws -> Void
    ) {
        self.profiles = profiles
        self.erase = erase
    }
}

@MainActor
public final class InMemoryTailscaleLocalStore: TailscaleLocalStoring {
    private var states: [UUID: TailscaleLocalState] = [:]
    private var cleanupProfiles: Set<UUID> = []
    public init() {}
    public func load() throws -> [TailscaleLocalState] { Array(states.values) }
    public func save(_ state: TailscaleLocalState) throws {
        if let old = states[state.groupID], old.profileID != state.profileID { cleanupProfiles.insert(old.profileID) }
        states[state.groupID] = state
        cleanupProfiles.remove(state.profileID)
    }
    public func remove(groupID: UUID) throws {
        if let old = states.removeValue(forKey: groupID) { cleanupProfiles.insert(old.profileID) }
    }
    public func scheduleCleanup(profileID: UUID) throws { cleanupProfiles.insert(profileID) }
    public func pendingCleanupProfiles() throws -> Set<UUID> {
        cleanupProfiles.subtracting(states.values.map(\.profileID))
    }
    public func completeCleanup(profileID: UUID) throws { cleanupProfiles.remove(profileID) }
}
