import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct TailscaleDeviceInfo: Sendable, Equatable {
    public var networkName: String
    public var dnsName: String
    public var hostname: String
    public var addresses: [String]
    public var operatingSystem: String
    public var keyExpiry: Date?

    public init(
        networkName: String, dnsName: String, hostname: String, addresses: [String], operatingSystem: String,
        keyExpiry: Date?
    ) {
        self.networkName = networkName
        self.dnsName = dnsName
        self.hostname = hostname
        self.addresses = addresses
        self.operatingSystem = operatingSystem
        self.keyExpiry = keyExpiry
    }
}

public nonisolated struct TailscaleNodeStatus: Sendable {
    public var running: Bool
    public var network: TailscaleNetwork?
    public var authURL: URL?
    public var peers: [TailscalePeer]
    public var device: TailscaleDeviceInfo?
    public init(
        running: Bool, network: TailscaleNetwork?, authURL: URL?, peers: [TailscalePeer],
        device: TailscaleDeviceInfo? = nil
    ) {
        self.running = running
        self.network = network
        self.authURL = authURL
        self.peers = peers
        self.device = device
    }
}

public nonisolated protocol TailscaleNodeSession: Sendable {
    func status() async throws -> TailscaleNodeStatus
    func login() async throws
    func logout() async throws
    func close() async
    func dial(host: String, port: Int, timeout: TimeInterval) async throws -> Int32
    func hostKeys(stableNodeID: String) async throws -> Set<SSHHostKeyIdentity>
    func setExitNode(_ stableID: String?) async throws
    func setHostname(_ hostname: String) async throws
    func ping(ip: String) async throws -> TailscalePingResult
}

extension TailscaleNodeSession {
    public func setExitNode(_ stableID: String?) async throws {
        if stableID != nil { throw TailscaleConfigurationError.unavailable }
    }
    public func setHostname(_ hostname: String) async throws { throw TailscaleConfigurationError.unavailable }
    public func ping(ip: String) async throws -> TailscalePingResult { throw TailscaleConfigurationError.unavailable }
}

public typealias TailscaleNodeFactory =
    @Sendable (
        _ profileID: UUID, _ hostname: String, _ controlURL: String, _ authKey: String?
    ) async throws -> any TailscaleNodeSession

@MainActor
@Observable
public final class TailscaleModel: TailscaleConnectionProviding {
    public private(set) var loginURL: URL?
    public private(set) var isLoggingIn = false
    public private(set) var loginCompletedGroupID: UUID?
    public private(set) var error: String?
    public private(set) var runningGroups: Set<UUID> = []
    public private(set) var devices: [UUID: TailscaleDeviceInfo] = [:]
    public private(set) var peers: [UUID: [TailscalePeer]] = [:]
    @ObservationIgnored private let library: HostLibraryModel
    @ObservationIgnored private let store: any TailscaleLocalStoring
    @ObservationIgnored private let factory: TailscaleNodeFactory
    @ObservationIgnored private let profileStorage: TailscaleProfileStorage
    @ObservationIgnored private let hostname: () -> String
    @ObservationIgnored private let hasAccess: () -> Bool
    @ObservationIgnored private var appliedExitNodes: [UUID: String] = [:]
    @ObservationIgnored private var states: [UUID: TailscaleLocalState] = [:]
    private nonisolated struct ActiveNode: Sendable {
        let session: any TailscaleNodeSession
        let profileID: UUID
        let network: TailscaleNetwork
    }
    @ObservationIgnored private var nodes: [UUID: ActiveNode] = [:]
    @ObservationIgnored private var monitors: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var starting: Set<UUID> = []
    @ObservationIgnored private var profilesInUse: Set<UUID> = []
    @ObservationIgnored private var retiringNodes: [UUID: any TailscaleNodeSession] = [:]
    @ObservationIgnored private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var loginGeneration: UUID?
    @ObservationIgnored private var loginTargetGroupID: UUID?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var shuttingDown = false

    public init(
        library: HostLibraryModel, store: any TailscaleLocalStoring,
        factory: @escaping TailscaleNodeFactory, profileStorage: TailscaleProfileStorage,
        hostname: @escaping () -> String,
        hasAccess: @escaping () -> Bool
    ) {
        self.library = library
        self.store = store
        self.factory = factory
        self.profileStorage = profileStorage
        self.hostname = hostname
        self.hasAccess = hasAccess
        library.tailscaleConnections = self
        library.didChangeTailscaleGroups = { [weak self] in self?.reconcile() }
    }

    public var defaultHostname: String { hostname() }

    public func savedHostname(groupID: UUID) -> String? { states[groupID]?.hostname }

    public func exitNodeID(groupID: UUID) -> String { library.group(groupID)?.tailscale?.exitNodeID ?? "" }

    public func exitNodeCandidates(groupID: UUID) -> [TailscalePeer] {
        (peers[groupID] ?? []).filter { $0.exitNodeOption == true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func saveExitNode(_ stableID: String, groupID: UUID) throws {
        guard hasAccess() else { throw TailscaleConfigurationError.requiresPro }
        guard var group = library.group(groupID), group.tailscale != nil else {
            throw TailscaleConfigurationError.unavailable
        }
        guard exitNodeID(groupID: groupID) != stableID else { return }
        group.tailscale?.exitNodeID = stableID.isEmpty ? nil : stableID
        library.upsert(group)
        if let error = library.storageError { throw TermindSSHError.library(error) }
    }

    public func saveHostname(_ value: String, groupID: UUID) async throws {
        guard hasAccess() else { throw TailscaleConfigurationError.requiresPro }
        guard var state = states[groupID] else { throw TailscaleConfigurationError.unavailable }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? hostname() : trimmed
        guard state.hostname != name else { return }
        if let node = nodes[groupID] { try await node.session.setHostname(name) }
        guard states[groupID]?.profileID == state.profileID else { throw CancellationError() }
        state = states[groupID] ?? state
        state.hostname = name
        try store.save(state)
        states[groupID] = state
        devices[groupID]?.hostname = name
    }

    public func start() {
        guard !started else { return }
        started = true
        do {
            states = Dictionary(uniqueKeysWithValues: try store.load().map { ($0.groupID, $0) })
            for var state in states.values {
                if state.hostname == nil {
                    state.hostname = hostname()
                    try store.save(state)
                    states[state.groupID] = state
                }
                peers[state.groupID] = state.peers
                library.replaceTailscalePeers(state.peers, groupID: state.groupID)
            }
            reconcile()
            recoverOrphanedProfiles()
        } catch { self.error = error.localizedDescription }
    }

    public func reconcile() {
        guard !shuttingDown else { return }
        if let id = loginTargetGroupID, library.group(id) == nil { cancelLogin() }
        guard library.storageError == nil else { return }
        let wanted = Set(library.groups.filter { $0.tailscale != nil }.map(\.id))
        for id in Set(states.keys).union(nodes.keys).subtracting(wanted) {
            retireProfile(groupID: id)
        }
        drainProfileCleanup()
        guard hasAccess() else { return }
        for id in wanted where nodes[id] == nil && !starting.contains(id) && loginTargetGroupID != id {
            guard let state = states[id], let configuration = library.group(id)?.tailscale else { continue }
            starting.insert(id)
            profilesInUse.insert(state.profileID)
            let name = state.hostname ?? hostname()
            Task { [weak self] in
                guard let self else { return }
                defer {
                    self.starting.remove(id)
                    self.profilesInUse.remove(state.profileID)
                    self.drainProfileCleanup()
                }
                do {
                    let node = try await self.factory(state.profileID, name, configuration.network.controlURL, nil)
                    guard !self.shuttingDown, self.states[id]?.profileID == state.profileID,
                        self.library.group(id)?.tailscale?.network == configuration.network, self.hasAccess()
                    else {
                        await node.close()
                        return
                    }
                    self.nodes[id] = ActiveNode(
                        session: node, profileID: state.profileID, network: configuration.network)
                    self.monitor(id, node: node)
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func recoverOrphanedProfiles() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let discovered = try await profileStorage.profiles()
                guard !shuttingDown, library.storageError == nil else { return }
                // Re-read after enumeration: a login may have committed while suspended.
                let active = Set(try store.load().map(\.profileID))
                for id in discovered.subtracting(active) { try store.scheduleCleanup(profileID: id) }
                drainProfileCleanup()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func retireProfile(groupID: UUID) {
        guard states[groupID] != nil else { return }
        do {
            // Remove the active reference and enqueue its profile atomically, before
            // releasing our last runtime reference. A failed save remains retryable.
            try store.remove(groupID: groupID)
            states[groupID] = nil
            if let node = nodes.removeValue(forKey: groupID) { retiringNodes[node.profileID] = node.session }
            monitors.removeValue(forKey: groupID)?.cancel()
            runningGroups.remove(groupID)
            devices[groupID] = nil
            appliedExitNodes[groupID] = nil
            peers[groupID] = nil
            library.replaceTailscalePeers([], groupID: groupID)
        } catch { self.error = error.localizedDescription }
    }

    private func drainProfileCleanup() {
        do {
            for id in try store.pendingCleanupProfiles()
            where !profilesInUse.contains(id) && !nodes.values.contains(where: { $0.profileID == id })
                && cleanupTasks[id] == nil
            {
                cleanupTasks[id] = Task { [weak self] in
                    guard let self else { return }
                    defer { self.cleanupTasks[id] = nil }
                    do {
                        guard !self.profilesInUse.contains(id),
                            !self.nodes.values.contains(where: { $0.profileID == id }),
                            try self.store.pendingCleanupProfiles().contains(id)
                        else { return }
                        if let node = self.retiringNodes.removeValue(forKey: id) {
                            try? await node.logout()
                            await node.close()
                        }
                        guard !self.profilesInUse.contains(id),
                            !self.nodes.values.contains(where: { $0.profileID == id }),
                            try self.store.pendingCleanupProfiles().contains(id)
                        else { return }
                        try await self.profileStorage.erase(id)
                        try self.store.completeCleanup(profileID: id)
                    } catch { self.error = error.localizedDescription }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    public func beginLogin(
        name: String, parentID: UUID?, controlURL: String, authKey: String?, groupID: UUID? = nil, hostname: String = ""
    ) {
        guard hasAccess() else {
            error = TailscaleConfigurationError.requiresPro.localizedDescription
            return
        }
        cancelLogin()
        let generation = UUID()
        let connectionID = groupID ?? UUID()
        loginGeneration = generation
        loginTargetGroupID = groupID
        let originalGroup = groupID.flatMap(library.group)
        isLoggingIn = true
        loginCompletedGroupID = nil
        error = nil
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = trimmedHostname.isEmpty ? self.hostname() : trimmedHostname
        loginTask = Task { [weak self] in
            guard let self else { return }
            var candidate: (any TailscaleNodeSession)?
            let profileID = UUID()
            self.profilesInUse.insert(profileID)
            defer {
                self.profilesInUse.remove(profileID)
                self.drainProfileCleanup()
            }
            do {
                let canonical = try TailscaleNetwork(controlURL: controlURL, dnsSuffix: "pending.invalid").controlURL
                try self.store.scheduleCleanup(profileID: profileID)
                let node = try await self.factory(profileID, deviceName, canonical, authKey)
                candidate = node
                try Task.checkCancellation()
                if authKey == nil { try await node.login() }
                let deadline = ContinuousClock.now.advanced(by: .seconds(600))
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    guard self.hasAccess() else { throw TailscaleConfigurationError.requiresPro }
                    let status = try await node.status()
                    try Task.checkCancellation()
                    guard self.loginGeneration == generation else { throw CancellationError() }
                    if let groupID, self.library.group(groupID) == nil { throw CancellationError() }
                    self.loginURL = status.authURL
                    if status.running, let network = status.network {
                        if let groupID, let previous = self.library.group(groupID)?.tailscale?.network,
                            previous != network
                        {
                            throw TailscaleConfigurationError.missingNetworkIdentity
                        }
                        var group =
                            groupID.flatMap(self.library.group)
                            ?? HostGroup(id: connectionID, name: name, parentID: parentID)
                        if group.tailscale == nil { group.tailscale = TailscaleGroupConfiguration(network: network) }
                        try await node.setExitNode(group.tailscale?.exitNodeID)
                        try Task.checkCancellation()
                        guard self.loginGeneration == generation else { throw CancellationError() }
                        guard self.hasAccess() else { throw TailscaleConfigurationError.requiresPro }
                        if let groupID {
                            guard let latest = self.library.group(groupID) else { throw CancellationError() }
                            guard latest.tailscale?.network == originalGroup?.tailscale?.network else {
                                throw CancellationError()
                            }
                            // Exit-node application suspends. Re-read cloud edits before committing
                            // enrollment, and apply a changed exit node on the next iteration.
                            if latest.tailscale?.exitNodeID != group.tailscale?.exitNodeID { continue }
                            group = latest
                            if group.tailscale == nil {
                                group.tailscale = TailscaleGroupConfiguration(network: network)
                            }
                        } else if self.library.group(group.id) != nil {
                            throw TailscaleConfigurationError.duplicateNetwork
                        }
                        let state = TailscaleLocalState(
                            groupID: group.id, profileID: profileID, peers: status.peers, hostname: deviceName)
                        if originalGroup == nil || group.name == originalGroup?.name { group.name = name }
                        if originalGroup == nil || group.parentID == originalGroup?.parentID {
                            group.parentID = parentID
                        }
                        // Public group configuration is valid without local enrollment.
                        // Persist it first so activation needs no cross-store rollback.
                        self.library.upsert(group)
                        guard self.library.storageError == nil else {
                            throw TailscaleConfigurationError.unavailable
                        }
                        try self.store.save(state)
                        self.monitors.removeValue(forKey: group.id)?.cancel()
                        if let old = self.nodes[group.id] {
                            self.retiringNodes[old.profileID] = old.session
                        }
                        self.states[group.id] = state
                        self.nodes[group.id] = ActiveNode(session: node, profileID: profileID, network: network)
                        self.appliedExitNodes[group.id] = group.tailscale?.exitNodeID ?? ""
                        self.library.replaceTailscalePeers(status.peers, groupID: group.id)
                        self.runningGroups.insert(group.id)
                        self.devices[group.id] = status.device
                        self.peers[group.id] = status.peers
                        self.monitor(group.id, node: node)
                        candidate = nil
                        self.loginURL = nil
                        self.loginCompletedGroupID = group.id
                        break
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                if candidate != nil { throw TailscaleConfigurationError.unavailable }
            } catch {
                if let candidate {
                    try? await candidate.logout()
                    await candidate.close()
                }
                if self.loginGeneration == generation && !(error is CancellationError) {
                    self.loginURL = nil
                    self.error = error.localizedDescription
                }
            }
            if self.loginGeneration == generation {
                self.isLoggingIn = false
                self.loginTargetGroupID = nil
            }
        }
    }

    public func cancelLogin() {
        loginGeneration = nil
        loginTargetGroupID = nil
        loginTask?.cancel()
        loginTask = nil
        loginURL = nil
        isLoggingIn = false
        // The login task owns its candidate and performs logout/close once, including
        // cancellation while factory, status, or preference application is suspended.
    }

    public func logout(groupID: UUID) async {
        let profileID = states[groupID]?.profileID
        retireProfile(groupID: groupID)
        drainProfileCleanup()
        if let profileID { await cleanupTasks[profileID]?.value }
    }

    public func connection(for groupID: UUID) throws -> any SSHNetworkDialing {
        guard hasAccess() else { throw TailscaleConfigurationError.requiresPro }
        guard runningGroups.contains(groupID), let node = nodes[groupID],
            library.group(groupID)?.tailscale?.network == node.network
        else {
            throw TailscaleConfigurationError.loginRequired
        }
        guard appliedExitNodes[groupID] == exitNodeID(groupID: groupID) else {
            throw TailscaleConfigurationError.settingsPending
        }
        return AccessDialer(
            node: node.session,
            check: { [weak self] in
                guard let self, self.hasAccess() else { throw TailscaleConfigurationError.requiresPro }
                guard self.runningGroups.contains(groupID), self.nodes[groupID]?.profileID == node.profileID,
                    self.library.group(groupID)?.tailscale?.network == node.network
                else { throw TailscaleConfigurationError.loginRequired }
                guard self.appliedExitNodes[groupID] == self.exitNodeID(groupID: groupID) else {
                    throw TailscaleConfigurationError.settingsPending
                }
            })
    }

    public func peer(for host: Host) -> TailscalePeer? {
        guard let group = library.tailscaleGroup(for: host) else { return nil }
        let candidates = peers[group.id] ?? []
        if let reference = host.tailscale {
            return candidates.first { $0.stableID == reference.stableNodeID }
        }
        let address = host.host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return candidates.first {
            $0.dnsName.lowercased() == address || $0.dnsName.split(separator: ".").first?.lowercased() == address
                || $0.details?.addresses.contains(address) == true
        }
    }

    public func canPing(_ host: Host) -> Bool {
        guard hasAccess(), let group = library.tailscaleGroup(for: host), runningGroups.contains(group.id) else {
            return false
        }
        return peer(for: host)?.details?.addresses.isEmpty == false
    }

    public func ping(hostID: Host.ID) async throws -> TailscalePingResult {
        guard hasAccess() else { throw TailscaleConfigurationError.requiresPro }
        guard let host = library.host(hostID), let group = library.tailscaleGroup(for: host),
            runningGroups.contains(group.id), let node = nodes[group.id], node.network == group.tailscale?.network,
            let ip = peer(for: host)?.details?.addresses.first
        else { throw TailscaleConfigurationError.unavailable }
        let result = try await node.session.ping(ip: ip)
        try Task.checkCancellation()
        guard hasAccess(), runningGroups.contains(group.id), nodes[group.id]?.profileID == node.profileID,
            library.tailscaleGroup(for: host)?.id == group.id,
            library.group(group.id)?.tailscale?.network == node.network
        else {
            throw TailscaleConfigurationError.unavailable
        }
        return result
    }

    public func shutdown() async {
        shuttingDown = true
        cancelLogin()
        for task in monitors.values { task.cancel() }
        monitors = [:]
        for node in nodes.values { await node.session.close() }
        nodes = [:]
        appliedExitNodes = [:]
        runningGroups = []
        devices = [:]
        peers = [:]
        for task in cleanupTasks.values { await task.value }
    }

    private func monitor(_ id: UUID, node: any TailscaleNodeSession) {
        monitors.removeValue(forKey: id)?.cancel()
        monitors[id] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let status = try await node.status()
                    try Task.checkCancellation()
                    guard let network = self.library.group(id)?.tailscale?.network else { return }
                    if status.running && status.network == network {
                        let desiredExitNode = self.exitNodeID(groupID: id)
                        if self.appliedExitNodes[id] != desiredExitNode {
                            guard self.hasAccess() else { throw TailscaleConfigurationError.requiresPro }
                            try await node.setExitNode(desiredExitNode.isEmpty ? nil : desiredExitNode)
                            try Task.checkCancellation()
                            self.appliedExitNodes[id] = desiredExitNode
                            guard self.exitNodeID(groupID: id) == desiredExitNode else { continue }
                        }
                        self.runningGroups.insert(id)
                        self.devices[id] = status.device
                        self.peers[id] = status.peers
                        self.library.replaceTailscalePeers(status.peers, groupID: id)
                        if var state = self.states[id], state.peers != status.peers {
                            state.peers = status.peers
                            try self.store.save(state)
                            self.states[id] = state
                        }
                    } else {
                        self.runningGroups.remove(id)
                        self.devices[id] = nil
                    }
                } catch {
                    if Task.isCancelled { return }
                    self.runningGroups.remove(id)
                    self.devices[id] = nil
                    self.error = error.localizedDescription
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
}

private nonisolated struct AccessDialer: SSHNetworkDialing {
    let node: any TailscaleNodeSession
    let check: @MainActor @Sendable () throws -> Void
    func open(host: String, port: Int, timeout: TimeInterval) async throws -> Int32 {
        try await check()
        return try await node.dial(host: host, port: port, timeout: timeout)
    }
    func hostKeys(stableNodeID: String) async throws -> Set<SSHHostKeyIdentity> {
        try await check()
        return try await node.hostKeys(stableNodeID: stableNodeID)
    }
}
