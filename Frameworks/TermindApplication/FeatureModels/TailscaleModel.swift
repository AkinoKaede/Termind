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

public nonisolated protocol TailscaleNodeSession: AnyObject, Sendable {
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

/// An authenticated candidate owned by an editor until the user saves it.
public nonisolated struct TailscalePendingLogin: Sendable, Identifiable {
    public let id: UUID
    public let groupID: UUID
    public let network: TailscaleNetwork
    public let exitNodeID: String
    public let suggestedName: String
    public let hostname: String
    public let peers: [TailscalePeer]
    public let device: TailscaleDeviceInfo?
}

@MainActor
@Observable
public final class TailscaleModel: TailscaleConnectionProviding {
    public private(set) var loginURL: URL?
    public private(set) var isLoggingIn = false
    public private(set) var loginCompletedGroupID: UUID?
    public private(set) var pendingLogin: TailscalePendingLogin?
    public private(set) var loginOperationID: UUID?
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
    @ObservationIgnored private var loginOriginalGroup: HostGroup?
    @ObservationIgnored private var candidateNode: ActiveNode?
    @ObservationIgnored private var committingProfileID: UUID?
    private var committingLogin: Bool { committingProfileID != nil }
    @ObservationIgnored private var knownNetworks: [UUID: TailscaleNetwork] = [:]
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
        knownNetworks = Dictionary(
            uniqueKeysWithValues: library.groups.compactMap { group in
                group.tailscale.map { (group.id, $0.network) }
            })
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
        if let id = loginTargetGroupID, !committingLogin {
            let latest = library.group(id)
            if (latest == nil) != (loginOriginalGroup == nil)
                || latest?.tailscale?.network != loginOriginalGroup?.tailscale?.network
            {
                cancelLogin()
            }
        }
        guard library.storageError == nil else { return }
        let networks = Dictionary(
            uniqueKeysWithValues: library.groups.compactMap { group in
                group.tailscale.map { (group.id, $0.network) }
            })
        let changed = Set(knownNetworks.keys.filter { knownNetworks[$0] != networks[$0] })
        for id in changed {
            runningGroups.remove(id)
            devices[id] = nil
            peers[id] = nil
            retireProfile(groupID: id)
        }
        // Keep failed retirements retryable even though the public binding has changed.
        for id in Set(knownNetworks.keys).union(networks.keys) where states[id] == nil || !changed.contains(id) {
            knownNetworks[id] = networks[id]
        }
        let wanted = Set(networks.keys)
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

    /// Authentication does not create or update a group. Only commitLogin publishes it.
    @discardableResult
    public func beginLogin(
        controlURL: String, authKey: String?, groupID: UUID = UUID(), hostname: String = ""
    ) -> UUID {
        cancelLogin()
        let generation = UUID()
        loginOperationID = generation
        loginGeneration = generation
        loginTargetGroupID = groupID
        loginOriginalGroup = library.group(groupID)
        loginCompletedGroupID = nil
        error = nil
        guard hasAccess(), !shuttingDown else {
            error = TailscaleConfigurationError.requiresPro.localizedDescription
            return generation
        }
        isLoggingIn = true
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = trimmedHostname.isEmpty ? self.hostname() : trimmedHostname
        loginTask = Task { [weak self] in
            guard let self else { return }
            var candidate: (any TailscaleNodeSession)?
            let profileID = UUID()
            self.profilesInUse.insert(profileID)
            defer {
                if self.candidateNode?.profileID != profileID { self.profilesInUse.remove(profileID) }
                self.drainProfileCleanup()
                if self.loginGeneration == generation { self.isLoggingIn = false }
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
                    try self.validateLogin(generation)
                    let status = try await node.status()
                    try self.validateLogin(generation)
                    self.loginURL = status.authURL
                    if status.running, let network = status.network {
                        let networkName =
                            status.device?.networkName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        self.candidateNode = ActiveNode(session: node, profileID: profileID, network: network)
                        self.pendingLogin = TailscalePendingLogin(
                            id: generation, groupID: groupID, network: network,
                            exitNodeID: self.library.group(groupID)?.tailscale?.network == network
                                ? self.exitNodeID(groupID: groupID) : "",
                            suggestedName: networkName.isEmpty ? network.dnsSuffix : networkName,
                            hostname: deviceName, peers: status.peers, device: status.device)
                        candidate = nil
                        self.loginURL = nil
                        return
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                throw TailscaleConfigurationError.unavailable
            } catch {
                if let candidate {
                    try? await candidate.logout()
                    await candidate.close()
                }
                if self.loginGeneration == generation {
                    self.loginURL = nil
                    if !(error is CancellationError) { self.error = error.localizedDescription }
                }
            }
        }
        return generation
    }

    private func validateLogin(_ id: UUID) throws {
        try Task.checkCancellation()
        guard !shuttingDown, loginGeneration == id, let groupID = loginTargetGroupID else {
            throw CancellationError()
        }
        guard hasAccess() else { throw TailscaleConfigurationError.requiresPro }
        let latest = library.group(groupID)
        guard (latest == nil) == (loginOriginalGroup == nil),
            latest?.tailscale?.network == loginOriginalGroup?.tailscale?.network
        else { throw TailscaleConfigurationError.unavailable }
    }

    public func group(_ id: UUID) -> HostGroup? { library.group(id) }

    /// The public binding is saved first. If local activation fails, the candidate
    /// remains owned by the editor so Save can retry without another browser login.
    public func commitLogin(
        _ id: UUID, group draft: HostGroup, hostname: String, exitNodeID: String
    ) async throws -> HostGroup {
        try validateLogin(id)
        guard !committingLogin, let pending = pendingLogin, pending.id == id,
            pending.groupID == draft.id, let candidate = candidateNode,
            !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw TailscaleConfigurationError.unavailable }
        committingProfileID = candidate.profileID
        defer {
            committingProfileID = nil
            if candidateNode?.profileID != candidate.profileID { profilesInUse.remove(candidate.profileID) }
            drainProfileCleanup()
        }
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = trimmed.isEmpty ? self.hostname() : trimmed
        // Re-read all public settings after operations that suspend.
        try await candidate.session.setHostname(deviceName)
        try validateLogin(id)
        func desiredExitNode() -> String {
            if exitNodeID == pending.exitNodeID, library.group(draft.id)?.tailscale?.network == pending.network {
                return self.exitNodeID(groupID: draft.id)
            }
            return exitNodeID
        }
        var status: TailscaleNodeStatus
        var selectedExitNode: String
        while true {
            selectedExitNode = desiredExitNode()
            try await candidate.session.setExitNode(selectedExitNode.isEmpty ? nil : selectedExitNode)
            try validateLogin(id)
            status = try await candidate.session.status()
            try validateLogin(id)
            guard status.running, status.network == pending.network else {
                throw TailscaleConfigurationError.loginRequired
            }
            if selectedExitNode == desiredExitNode() { break }
        }
        var group = library.group(draft.id) ?? draft
        if group.tailscale?.network != pending.network {
            group.tailscale = TailscaleGroupConfiguration(network: pending.network)
        }
        if loginOriginalGroup == nil || draft.name != loginOriginalGroup?.name {
            group.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if loginOriginalGroup == nil || draft.parentID != loginOriginalGroup?.parentID {
            group.parentID = draft.parentID
        }
        group.tailscale?.exitNodeID = selectedExitNode.isEmpty ? nil : selectedExitNode
        library.upsert(group)
        if let error = library.storageError { throw TermindSSHError.library(error) }
        // A retry must compare against the binding we have just durably saved.
        loginOriginalGroup = group
        let state = TailscaleLocalState(
            groupID: group.id, profileID: candidate.profileID, peers: status.peers, hostname: deviceName)
        do {
            try store.save(state)
        } catch {
            let message = String(
                localized: "The group was saved, but this device could not finish signing in. Save again to retry.")
            self.error = message
            throw TermindSSHError.library(message)
        }
        monitors.removeValue(forKey: group.id)?.cancel()
        if let old = nodes[group.id] { retiringNodes[old.profileID] = old.session }
        states[group.id] = state
        nodes[group.id] = candidate
        knownNetworks[group.id] = pending.network
        appliedExitNodes[group.id] = selectedExitNode
        library.replaceTailscalePeers(status.peers, groupID: group.id)
        runningGroups.insert(group.id)
        devices[group.id] = status.device
        peers[group.id] = status.peers
        candidateNode = nil
        pendingLogin = nil
        profilesInUse.remove(candidate.profileID)
        loginTargetGroupID = nil
        loginGeneration = nil
        loginOperationID = nil
        loginCompletedGroupID = group.id
        self.error = nil
        monitor(group.id, node: candidate.session)
        drainProfileCleanup()
        return group
    }

    public func saveGroup(
        _ draft: HostGroup, original: HostGroup?, enabled: Bool, exitNodeID: String? = nil
    ) throws -> HostGroup {
        let latest = library.group(draft.id)
        guard (latest == nil) == (original == nil), latest?.tailscale?.network == original?.tailscale?.network else {
            throw TailscaleConfigurationError.unavailable
        }
        var group = latest ?? draft
        if original == nil || draft.name != original?.name {
            group.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !group.name.isEmpty else { throw TailscaleConfigurationError.unavailable }
        if original == nil || draft.parentID != original?.parentID { group.parentID = draft.parentID }
        if !enabled { group.tailscale = nil }
        if let exitNodeID, enabled { group.tailscale?.exitNodeID = exitNodeID.isEmpty ? nil : exitNodeID }
        library.upsert(group)
        if let error = library.storageError { throw TermindSSHError.library(error) }
        return group
    }

    public func cancelLogin(operationID: UUID? = nil) {
        if let operationID, operationID != loginOperationID { return }
        loginGeneration = nil
        loginOperationID = nil
        loginTargetGroupID = nil
        loginOriginalGroup = nil
        loginTask?.cancel()
        loginTask = nil
        loginURL = nil
        isLoggingIn = false
        pendingLogin = nil
        if let candidate = candidateNode {
            candidateNode = nil
            // A Save can be suspended inside the native runtime. Its defer releases
            // the final profile lease before logout, close and directory erasure.
            if committingProfileID != candidate.profileID { profilesInUse.remove(candidate.profileID) }
            retiringNodes[candidate.profileID] = candidate.session
            drainProfileCleanup()
        }
        // The authentication task owns a candidate until it publishes pendingLogin.
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
        let authentication = loginTask
        cancelLogin()
        await authentication?.value
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
                    guard self.nodes[id]?.session === node,
                        let network = self.library.group(id)?.tailscale?.network
                    else { return }
                    if status.running, status.network != network {
                        self.retireProfile(groupID: id)
                        self.drainProfileCleanup()
                        return
                    }
                    if status.running && status.network == network {
                        let desiredExitNode = self.exitNodeID(groupID: id)
                        if self.appliedExitNodes[id] != desiredExitNode {
                            guard self.hasAccess() else { throw TailscaleConfigurationError.requiresPro }
                            try await node.setExitNode(desiredExitNode.isEmpty ? nil : desiredExitNode)
                            try Task.checkCancellation()
                            guard self.nodes[id]?.session === node,
                                self.library.group(id)?.tailscale?.network == network
                            else { return }
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
