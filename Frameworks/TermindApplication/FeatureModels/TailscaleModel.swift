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
    @ObservationIgnored private let hostname: () -> String
    @ObservationIgnored private let hasAccess: () -> Bool
    @ObservationIgnored private var appliedExitNodes: [UUID: String] = [:]
    @ObservationIgnored private var states: [UUID: TailscaleLocalState] = [:]
    @ObservationIgnored private var nodes: [UUID: any TailscaleNodeSession] = [:]
    @ObservationIgnored private var monitors: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var starting: Set<UUID> = []
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var loginGeneration: UUID?
    @ObservationIgnored private var pendingNode: (any TailscaleNodeSession)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var shuttingDown = false

    public init(
        library: HostLibraryModel, store: any TailscaleLocalStoring,
        factory: @escaping TailscaleNodeFactory, hostname: @escaping () -> String,
        hasAccess: @escaping () -> Bool
    ) {
        self.library = library
        self.store = store
        self.factory = factory
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
        if let node = nodes[groupID] { try await node.setHostname(name) }
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
        } catch { self.error = error.localizedDescription }
    }

    public func reconcile() {
        guard !shuttingDown else { return }
        let wanted = Set(library.groups.filter { $0.tailscale != nil }.map(\.id))
        for id in Set(states.keys).union(nodes.keys).subtracting(wanted) {
            monitors.removeValue(forKey: id)?.cancel()
            runningGroups.remove(id)
            devices[id] = nil
            appliedExitNodes[id] = nil
            peers[id] = nil
            if let node = nodes.removeValue(forKey: id) {
                Task {
                    try? await node.logout()
                    await node.close()
                }
            }
            states[id] = nil
            do { try store.remove(groupID: id) } catch { self.error = error.localizedDescription }
            library.replaceTailscalePeers([], groupID: id)
        }
        guard hasAccess() else { return }
        for id in wanted where nodes[id] == nil && !starting.contains(id) {
            guard let state = states[id], let configuration = library.group(id)?.tailscale else { continue }
            starting.insert(id)
            let name = state.hostname ?? hostname()
            Task { [weak self] in
                guard let self else { return }
                defer { self.starting.remove(id) }
                do {
                    let node = try await self.factory(state.profileID, name, configuration.network.controlURL, nil)
                    guard !self.shuttingDown, self.states[id]?.profileID == state.profileID,
                        self.library.group(id)?.tailscale?.network == configuration.network, self.hasAccess()
                    else {
                        await node.close()
                        return
                    }
                    self.nodes[id] = node
                    self.monitor(id, node: node)
                } catch { self.error = error.localizedDescription }
            }
        }
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
        loginGeneration = generation
        isLoggingIn = true
        loginCompletedGroupID = nil
        error = nil
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = trimmedHostname.isEmpty ? self.hostname() : trimmedHostname
        loginTask = Task { [weak self] in
            guard let self else { return }
            var candidate: (any TailscaleNodeSession)?
            do {
                let canonical = try TailscaleNetwork(controlURL: controlURL, dnsSuffix: "pending.invalid").controlURL
                let profileID = UUID()
                let node = try await self.factory(profileID, deviceName, canonical, authKey)
                candidate = node
                try Task.checkCancellation()
                self.pendingNode = node
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
                        if self.library.groups.contains(where: { $0.tailscale?.network == network && $0.id != groupID })
                        {
                            throw TailscaleConfigurationError.duplicateNetwork
                        }
                        var group =
                            groupID.flatMap(self.library.group)
                            ?? HostGroup(id: network.groupID, name: name, parentID: parentID)
                        if group.tailscale == nil { group.tailscale = TailscaleGroupConfiguration(network: network) }
                        try await node.setExitNode(group.tailscale?.exitNodeID)
                        try Task.checkCancellation()
                        guard self.loginGeneration == generation else { throw CancellationError() }
                        let state = TailscaleLocalState(
                            groupID: group.id, profileID: profileID, peers: status.peers, hostname: deviceName)
                        group.name = name
                        group.parentID = parentID
                        let previousState = self.states[group.id]
                        try self.store.save(state)
                        self.library.upsert(group)
                        guard self.library.storageError == nil else {
                            if let previousState {
                                try self.store.save(previousState)
                            } else {
                                try self.store.remove(groupID: group.id)
                            }
                            throw TailscaleConfigurationError.unavailable
                        }
                        self.monitors.removeValue(forKey: group.id)?.cancel()
                        if let old = self.nodes[group.id] {
                            Task {
                                try? await old.logout()
                                await old.close()
                            }
                        }
                        self.states[group.id] = state
                        self.nodes[group.id] = node
                        self.appliedExitNodes[group.id] = group.tailscale?.exitNodeID ?? ""
                        self.library.replaceTailscalePeers(status.peers, groupID: group.id)
                        self.runningGroups.insert(group.id)
                        self.devices[group.id] = status.device
                        self.peers[group.id] = status.peers
                        self.monitor(group.id, node: node)
                        self.pendingNode = nil
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
                self.pendingNode = nil
            }
        }
    }

    public func cancelLogin() {
        loginGeneration = nil
        loginTask?.cancel()
        loginTask = nil
        loginURL = nil
        isLoggingIn = false
        if let node = pendingNode {
            Task {
                try? await node.logout()
                await node.close()
            }
        }
        pendingNode = nil
    }

    public func logout(groupID: UUID) async {
        monitors.removeValue(forKey: groupID)?.cancel()
        runningGroups.remove(groupID)
        devices[groupID] = nil
        peers[groupID] = nil
        appliedExitNodes[groupID] = nil
        let node = nodes.removeValue(forKey: groupID)
        states[groupID] = nil
        do { try store.remove(groupID: groupID) } catch { self.error = error.localizedDescription }
        library.replaceTailscalePeers([], groupID: groupID)
        if let node {
            try? await node.logout()
            await node.close()
        }
    }

    public func connection(for groupID: UUID) throws -> any SSHNetworkDialing {
        guard hasAccess() else { throw TailscaleConfigurationError.requiresPro }
        guard runningGroups.contains(groupID), let node = nodes[groupID] else {
            throw TailscaleConfigurationError.loginRequired
        }
        guard appliedExitNodes[groupID] == exitNodeID(groupID: groupID) else {
            throw TailscaleConfigurationError.settingsPending
        }
        return AccessDialer(
            node: node,
            check: { [weak self] in
                guard let self, self.hasAccess() else { throw TailscaleConfigurationError.requiresPro }
                guard self.runningGroups.contains(groupID) else { throw TailscaleConfigurationError.loginRequired }
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
            runningGroups.contains(group.id), let node = nodes[group.id],
            let ip = peer(for: host)?.details?.addresses.first
        else { throw TailscaleConfigurationError.unavailable }
        let result = try await node.ping(ip: ip)
        try Task.checkCancellation()
        guard hasAccess(), runningGroups.contains(group.id), library.tailscaleGroup(for: host)?.id == group.id else {
            throw TailscaleConfigurationError.unavailable
        }
        return result
    }

    public func shutdown() async {
        shuttingDown = true
        cancelLogin()
        for task in monitors.values { task.cancel() }
        monitors = [:]
        for node in nodes.values { await node.close() }
        nodes = [:]
        appliedExitNodes = [:]
        runningGroups = []
        devices = [:]
        peers = [:]
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
