// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

import struct TermindDomain.Host

/// The single source of truth for saved hosts, groups, keys, snippets, and port
/// forwarding rules.
///
/// Core host metadata is backed by SwiftData in the app and projected into value
/// types for the views. Previews can still construct an in-memory store directly.
@Observable
public final class HostLibraryModel: RemoteSessionHostStore {
    public var hostAccess = HostAccessPolicy(entitlement: .unrestrictedForTesting) {
        didSet { operationAccess.update(policy: hostAccess, hosts: hosts) }
    }
    @ObservationIgnored private let operationAccess = HostOperationAccess()
    public func connectionAccessCheck(for hostIDs: [UUID]) -> HostOperationAccessCheck? {
        let access = operationAccess
        return { try access.check(hostIDs) }
    }
    @ObservationIgnored public var requestHostUpgrade: (() -> Void)?
    @ObservationIgnored public var resolveInitialHostEntitlement: (() async -> Void)?
    public func isLocked(_ host: Host) -> Bool { hostAccess.isLocked(host.id, in: hosts) }

    public func requireHostAccess(_ host: Host, protocol connectionProtocol: HostTerminalProtocol) throws {
        for node in connectionProtocol == .telnet ? [host] : route(for: host) {
            try hostAccess.requireAccess(to: node.id, in: hosts)
        }
    }

    public func resolveHostAccess(
        _ host: Host, protocol connectionProtocol: HostTerminalProtocol
    ) async throws {
        do { try requireHostAccess(host, protocol: connectionProtocol) } catch HostAccessError.verifyingEntitlement {
            await resolveInitialHostEntitlement?()
            try Task.checkCancellation()
            try requireHostAccess(host, protocol: connectionProtocol)
        }
    }

    public func resolveSavingHostsAccess(_ proposed: [Host], requestsUpgrade: Bool = true) async throws {
        do { try hostAccess.requireSaving(proposed, in: hosts) } catch {
            if case HostAccessError.verifyingEntitlement = error {
                await resolveInitialHostEntitlement?()
                try Task.checkCancellation()
            }
        }
        if requestsUpgrade {
            try requireSavingHosts(proposed)
        } else {
            try hostAccess.requireSaving(proposed, in: hosts)
        }
    }

    public func requireSavingHosts(_ proposed: [Host]) throws {
        do {
            try hostAccess.requireSaving(proposed, in: hosts)
        } catch let error as HostAccessError {
            if error == .hostLimit { requestHostUpgrade?() }
            throw error
        }
    }
    @ObservationIgnored public weak var tailscaleConnections: (any TailscaleConnectionProviding)?
    @ObservationIgnored public var didChangeTailscaleGroups: (() -> Void)?
    /// Retires managed sessions when a binding is removed or replaced by another network.
    @ObservationIgnored public var didDeleteTailscaleGroups: ((Set<UUID>, Set<UUID>) -> Void)?
    private var tailscalePeers: [UUID: [TailscalePeer]] = [:]
    public private(set) var hosts: [Host] = [] {
        didSet {
            operationAccess.update(policy: hostAccess, hosts: hosts)
            for old in oldValue where old.agentForwardingEnabled {
                if !hosts.contains(where: { $0.id == old.id && $0.agentForwardingEnabled }) {
                    agentForwardingRevisions[old.id, default: 0] += 1
                }
            }
        }
    }
    @ObservationIgnored private var agentForwardingRevisions: [UUID: UInt64] = [:]
    public func agentForwardingRevision(for hostID: UUID) -> UInt64 {
        agentForwardingRevisions[hostID, default: 0]
    }
    public var agentForwardingSecrets: any SSHRuntimeSecretResolving { keychain }

    public private(set) var groups: [HostGroup] = []
    public private(set) var keys: [SSHKeyRef] = [] {
        didSet { if oldValue != keys { keyCredentialRevision &+= 1 } }
    }
    public var agentForwardingKeyRevision: Int { keyCredentialRevision }
    public private(set) var identities: [Identity] = []
    /// Invalidates editor availability projections even when a password keeps the same reference.
    public private(set) var passwordAvailabilityRevision: UInt64 = 0
    public private(set) var snippets: [Snippet] = []
    public private(set) var snippetPackages: [SnippetPackage] = []
    public private(set) var portForwardings: [PortForwardingRule] = []
    public private(set) var sftpTransfers: [SFTPTransfer] = []
    @ObservationIgnored public var sftpTransferStateDidChange: ((SFTPTransfer) -> Void)?
    @ObservationIgnored public var sftpTransfersDidRemove: ((Set<UUID>) -> Void)?
    public private(set) var knownHosts: [KnownHostEntry] = []
    public private(set) var workspaceTemplates: [WorkspaceTemplate] = []

    /// The latest local persistence failure. Secret text is never included.
    public private(set) var storageError: String?
    private let vault: VaultStore
    private var keyCredentialRevision = 0
    private let keychain: any SecretStoring
    private let defaults: UserDefaults
    private var expansionState = LibraryExpansionState()
    @ObservationIgnored public var wakeOnLAN: WakeOnLANController?

    public func connectionWakeAction(for hostIDs: [UUID]) -> ConnectionWakeAction? {
        guard wakeOnLAN != nil else { return nil }
        return { [weak self] in
            await self?.wakeBeforeConnecting(hostIDs)
        }
    }

    private func wakeBeforeConnecting(_ ids: [UUID]) {
        guard
            ids.allSatisfy({ id in
                (try? hostAccess.requireAccess(to: id, in: hosts)) != nil
            })
        else { return }
        for id in ids {
            guard !Task.isCancelled else { return }
            if let host = host(id) { wakeOnLAN?.automaticallyWake(host.wakeOnLAN) }
        }
    }

    /// Runtime resources live in AppModel, so deletion announces before model
    /// references are removed and the controller can stop listeners cleanly.
    public var willDeleteHost: ((Host.ID, [PortForwardingRule.ID]) -> Void)?
    public var willDeletePortForwardings: (([PortForwardingRule.ID]) -> Void)?
    public var didChangeHostConnection: ((Host.ID) -> Void)?
    public var didChangeTelnetConnection: ((Host.ID) -> Void)?
    public var didPersistCore: (() -> Void)? {
        get { vault.didPersist }
        set { vault.didPersist = newValue }
    }
    public var didRecordVaultChanges: ((VaultMutationSet) -> Void)? {
        get { vault.didRecordChanges }
        set { vault.didRecordChanges = newValue }
    }

    public func reportStorageError(_ error: any Error) {
        storageError = error.localizedDescription
    }

    /// Live connection state, keyed by host. Lives here rather than on `Host`
    /// because it is session state, not user data — it must never be persisted
    /// or synced.
    public private(set) var statuses: [Host.ID: ConnectionStatus] = [:]
    private var connectionStatuses: [UUID: (hostID: Host.ID, status: ConnectionStatus)] = [:]

    public var isUngroupedExpanded: Bool { expansionState.isHostsUngroupedExpanded }
    public var isSnippetsUngroupedExpanded: Bool { expansionState.isSnippetsUngroupedExpanded }

    public init(
        hosts: [Host] = [],
        groups: [HostGroup] = [],
        keys: [SSHKeyRef] = [],
        identities: [Identity] = [],
        snippets: [Snippet] = [],
        snippetPackages: [SnippetPackage] = [],
        portForwardings: [PortForwardingRule] = [],
        sftpTransfers: [SFTPTransfer] = [],
        knownHosts: [KnownHostEntry] = [],
        workspaceTemplates: [WorkspaceTemplate] = [],
        persistence: (any VaultPersisting)? = nil,
        secrets: any SecretStoring = InMemorySecretStore(),
        localDefaults: UserDefaults? = nil
    ) {
        self.hosts = hosts
        self.groups = groups
        self.keys = normalizedManualOrder(
            keys, sortIndex: \SSHKeyRef.sortIndex, name: \SSHKeyRef.label
        )
        self.identities = normalizedManualOrder(
            identities, sortIndex: \Identity.sortIndex, name: \Identity.name
        )
        self.snippets = normalizedSnippetOrder(snippets)
        self.snippetPackages = snippetPackages
        self.portForwardings = portForwardings
        self.sftpTransfers = sftpTransfers
        self.knownHosts = knownHosts
        self.workspaceTemplates = workspaceTemplates
        self.vault = VaultStore(persistence: persistence)
        self.keychain = secrets
        self.defaults = localDefaults ?? .standard
        do {
            let loaded = try vault.load(
                fallback: VaultSnapshot(
                    hosts: hosts, groups: groups, identities: identities, keys: keys,
                    knownHosts: knownHosts, snippets: snippets,
                    snippetPackages: snippetPackages, portForwardings: portForwardings,
                    workspaceTemplates: workspaceTemplates
                )
            )
            self.hosts = loaded.hosts
            self.groups = loaded.groups
            self.identities = loaded.identities.sorted {
                manuallyOrdered($0.sortIndex, $0.name, $1.sortIndex, $1.name)
            }
            self.keys = loaded.keys.sorted {
                manuallyOrdered($0.sortIndex, $0.label, $1.sortIndex, $1.label)
            }
            self.knownHosts = loaded.knownHosts
            self.snippets = loaded.snippets.sorted { $0.sortIndex < $1.sortIndex }
            self.snippetPackages = loaded.snippetPackages
            self.portForwardings = loaded.portForwardings
            self.workspaceTemplates = loaded.workspaceTemplates
        } catch {
            storageError = error.localizedDescription
        }
        expansionState = LibraryExpansionState(
            defaults: localDefaults,
            legacyGroups: self.groups,
            legacySnippetPackages: self.snippetPackages
        )
        reconcileExpansionState()
    }

    // MARK: - Reads

    public func host(_ id: Host.ID) -> Host? {
        hosts.first { $0.id == id }
    }

    public func group(_ id: HostGroup.ID) -> HostGroup? {
        groups.first { $0.id == id }
    }

    public func isHostGroupExpanded(_ id: HostGroup.ID) -> Bool {
        expansionState.isHostGroupExpanded(id)
    }

    public func snippet(_ id: Snippet.ID) -> Snippet? {
        snippets.first { $0.id == id }
    }

    public func snippetModifiedAt(_ id: Snippet.ID) -> Date? {
        vault.modifiedAt(for: VaultRecordKey(kind: .snippet, id: id))
    }

    public func identityModifiedAt(_ id: Identity.ID) -> Date? {
        vault.modifiedAt(for: VaultRecordKey(kind: .identity, id: id))
    }

    public func snippetPackage(_ id: SnippetPackage.ID) -> SnippetPackage? {
        snippetPackages.first { $0.id == id }
    }

    public func isSnippetPackageExpanded(_ id: SnippetPackage.ID) -> Bool {
        expansionState.isSnippetPackageExpanded(id)
    }

    public var rootSnippetPackages: [SnippetPackage] {
        snippetPackages.filter { $0.parentID == nil }.sorted { $0.sortIndex < $1.sortIndex }
    }

    public func childSnippetPackages(of parent: SnippetPackage.ID) -> [SnippetPackage] {
        snippetPackages.filter { $0.parentID == parent }.sorted { $0.sortIndex < $1.sortIndex }
    }

    public func descendantSnippetPackages(of parent: SnippetPackage.ID) -> [SnippetPackage] {
        childSnippetPackages(of: parent).flatMap {
            [$0] + descendantSnippetPackages(of: $0.id)
        }
    }

    public func snippets(in package: SnippetPackage.ID?) -> [Snippet] {
        snippets.filter { $0.packageID == package }.sorted { $0.sortIndex < $1.sortIndex }
    }

    public func snippetPackagePath(_ packageID: SnippetPackage.ID?) -> String? {
        guard let packageID, let package = snippetPackage(packageID) else { return nil }
        var names = [package.name]
        var parentID = package.parentID
        var visited: Set<SnippetPackage.ID> = [package.id]
        while let id = parentID, let parent = snippetPackage(id), visited.insert(id).inserted {
            names.append(parent.name)
            parentID = parent.parentID
        }
        return names.reversed().joined(separator: " / ")
    }

    public func status(of id: Host.ID) -> ConnectionStatus {
        if statuses[id] == .connected { return .connected }
        if sftpTransfers.contains(where: {
            $0.involves(id) && $0.state == .running
        }) {
            return .connected
        }
        if let status = statuses[id] { return status }
        if sftpTransfers.contains(where: {
            $0.involves(id) && $0.state == .queued
        }) {
            return .connecting
        }
        return .disconnected
    }

    /// Top-level groups, in sort order.
    public var rootGroups: [HostGroup] {
        groups.filter { $0.parentID == nil }.sorted { $0.sortIndex < $1.sortIndex }
    }

    public func childGroups(of parent: HostGroup.ID) -> [HostGroup] {
        groups.filter { $0.parentID == parent }.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Every group below `parent`, at any depth, parents before children.
    ///
    /// What a delete has to take with it, and — read the other way — the set a
    /// group may *not* be re-filed into, since a group cannot become its own
    /// descendant.
    public func descendantGroups(of parent: HostGroup.ID) -> [HostGroup] {
        childGroups(of: parent).flatMap { [$0] + descendantGroups(of: $0.id) }
    }

    /// Hosts directly inside a group — `nil` means "not filed in any group".
    public func hosts(in group: HostGroup.ID?) -> [Host] {
        hosts.filter { $0.groupID == group }.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Hosts anywhere in a group's subtree. The number a delete has to warn
    /// about: deleting Production takes Edge with it, so the machines filed in
    /// Edge are just as much at stake as the ones filed in Production.
    public func hosts(inTreeOf group: HostGroup.ID) -> [Host] {
        let tree = Set([group] + descendantGroups(of: group).map(\.id))
        return hosts.filter { host in host.groupID.map(tree.contains) ?? false }
    }

    public func portForwardings(for host: Host.ID) -> [PortForwardingRule] {
        portForwardings.filter { $0.hostID == host }
    }

    public func portForwarding(_ id: PortForwardingRule.ID) -> PortForwardingRule? {
        portForwardings.first { $0.id == id }
    }

    public var sortedWorkspaceTemplates: [WorkspaceTemplate] {
        workspaceTemplates.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func workspaceTemplate(_ id: WorkspaceTemplate.ID) -> WorkspaceTemplate? {
        workspaceTemplates.first { $0.id == id }
    }

    @discardableResult
    public func saveWorkspaceTemplate(_ template: WorkspaceTemplate) -> Bool {
        var template = template
        template.name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard template.isValid else {
            storageError = String(localized: "The Workspace template is invalid.")
            return false
        }
        guard
            !workspaceTemplates.contains(where: {
                $0.id != template.id
                    && $0.name.compare(template.name, options: [.caseInsensitive, .diacriticInsensitive])
                        == .orderedSame
            })
        else {
            storageError = String(localized: "A Workspace template with this name already exists.")
            return false
        }

        let previous = workspaceTemplates
        if let index = workspaceTemplates.firstIndex(where: { $0.id == template.id }) {
            workspaceTemplates[index] = template
        } else {
            workspaceTemplates.append(template)
        }
        guard persistCore() else {
            workspaceTemplates = previous
            return false
        }
        return true
    }

    @discardableResult
    public func renameWorkspaceTemplate(_ id: WorkspaceTemplate.ID, to name: String) -> Bool {
        guard var template = workspaceTemplate(id) else { return false }
        template.name = name
        return saveWorkspaceTemplate(template)
    }

    @discardableResult
    public func deleteWorkspaceTemplate(_ id: WorkspaceTemplate.ID) -> Bool {
        let previous = workspaceTemplates
        workspaceTemplates.removeAll { $0.id == id }
        guard workspaceTemplates.count != previous.count else { return false }
        guard persistCore() else {
            workspaceTemplates = previous
            return false
        }
        return true
    }

    public func sftpTransfers(for host: Host.ID) -> [SFTPTransfer] {
        sftpTransfers.filter { $0.involves(host) }
    }

    public func key(_ id: SSHKeyRef.ID) -> SSHKeyRef? {
        keys.first { $0.id == id }
    }

    public func identity(_ id: Identity.ID) -> Identity? {
        identities.first { $0.id == id }
    }

    public var reusableIdentities: [Identity] {
        identities.filter { !$0.isHostCustom }
    }

    public func customIdentity(for hostID: Host.ID, purpose: HostCustomIdentityPurpose) -> Identity? {
        identities.first { $0.ownerHostID == hostID && $0.customPurpose == purpose }
    }

    /// The login a host connects with, resolved through the store so renaming an
    /// identity renames it everywhere it is shown.
    public func identity(for host: Host) -> Identity? {
        identity(for: host, protocol: .ssh)
    }

    public func identity(for host: Host, protocol connectionProtocol: HostTerminalProtocol) -> Identity? {
        guard !host.isTailscaleManaged else { return nil }
        return host.identityID(for: connectionProtocol).flatMap { identity($0) }
    }

    /// `user@host:port` — what the UI shows almost everywhere a host is named.
    ///
    /// Falls back to the bare address when no identity is set, rather than
    /// inventing a login: a host that does not yet know who it connects as
    /// should look like one.
    public func loginAddress(for host: Host) -> String {
        loginAddress(for: host, protocol: .ssh)
    }

    public func loginAddress(for host: Host, protocol connectionProtocol: HostTerminalProtocol) -> String {
        let address = host.displayAddress(for: connectionProtocol)
        guard
            let username = host.isTailscaleManaged
                ? savedTailscaleUsername(for: host) : identity(for: host, protocol: connectionProtocol)?.username,
            !username.isEmpty
        else {
            return address
        }
        return "\(username)@\(address)"
    }

    public func preferredTerminalLoginAddress(for host: Host) -> String {
        guard let connectionProtocol = host.preferredTerminalProtocol else { return host.host }
        return loginAddress(for: host, protocol: connectionProtocol)
    }

    /// Which identities would break if a key were deleted. The Keys list shows
    /// this count, because "delete" needs to say what it takes with it.
    public func identities(using key: SSHKeyRef.ID) -> [Identity] {
        identities.filter { $0.keyID == key }
    }

    /// The pinned host keys for a saved host, matched the way OpenSSH matches:
    /// hostname plus port. Newest keys are shown first in the host's details.
    public func knownHosts(for host: Host) -> [KnownHostEntry] {
        guard !host.isTailscaleManaged else { return [] }
        return
            knownHosts
            .filter { $0.matches(hostname: host.host, port: host.port) }
            .sorted {
                if $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
                if $0.fingerprint != $1.fingerprint { return $0.fingerprint < $1.fingerprint }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    /// Resolves persistent trust plus approvals scoped to the current connection
    /// journey. Temporary approvals never enter SwiftData or sync.
    public func expectedHostKeys(
        for host: Host, temporaryHostKeys: [Host.ID: SSHHostKeyIdentity] = [:],
        trustPolicy: SSHHostTrustPolicy = .requireKnownHost
    ) throws -> Set<SSHHostKeyIdentity> {
        var keys = Set(knownHosts(for: host).map(\.identity))
        if let temporary = temporaryHostKeys[host.id] {
            keys.insert(temporary)
        }
        if trustPolicy == .requireKnownHost, keys.isEmpty {
            throw TermindSSHError.untrustedHost
        }
        return keys
    }

    public func keyExportUnavailableReason(for host: Host) -> String? {
        isEligible(host, for: .keyExport) ? nil : HostProtocolUnavailableError(useCase: .keyExport).localizedDescription
    }

    /// Resolves model references and Keychain secrets before work leaves the
    /// main actor. The resulting value is Sendable and contains no persistence
    /// objects, so several one-shot exports can safely run in parallel.
    public func prepareSSHConnection(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission] = [:]
    ) throws -> SSHConnectionPreparation {
        try require(host, for: .sshTerminal)
        guard let route = validatedRoute(for: host) else {
            throw TermindSSHError.route(String(localized: "The Jump Host route is invalid or exceeds eight hosts."))
        }
        return try prepareSSHConnection(
            for: SSHConnectionRoute(hosts: route), submissions: submissions,
            proxySubmissions: proxySubmissions)
    }

    public func telnetConnectionConfiguration(for host: Host) throws -> TelnetConnectionConfiguration {
        try require(host, for: .telnetTerminal)
        let identity = identity(for: host, protocol: .telnet)
        let username = identity?.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password: SSHSecret?
        if let identity, identity.usesPassword {
            password = try connectionPasswordSecret(for: identity)
            guard password != nil else { throw TermindSSHError.missingCredential }
        } else {
            password = nil
        }
        var configuration = TelnetConnectionConfiguration(
            host: host.host, port: host.telnetPort,
            username: username?.isEmpty == false ? username : nil,
            password: password, charset: host.telnetCharset,
            proxy: try terminalTransportProxy(for: host.telnetProxy, ownerHostID: host.id)
        )
        configuration.accessCheck = connectionAccessCheck(for: [host.id])
        configuration.beforeConnect = connectionWakeAction(for: [host.id])
        return configuration
    }

    private func terminalTransportProxy(
        for proxy: HostProxy?, ownerHostID: Host.ID
    ) throws -> TerminalTransportProxy? {
        guard let proxy else { return nil }
        guard proxy.isValid else {
            throw TermindSSHError.proxy(String(localized: "The proxy configuration is incomplete."))
        }
        var password: SSHSecret?
        if let identityID = proxy.identityID {
            guard let identity = identity(identityID), identity.usesPassword else {
                throw TermindSSHError.proxyAuthentication(
                    hostID: ownerHostID, serverChallenge: false,
                    message: String(localized: "The proxy password identity is unavailable."))
            }
            password = try connectionPasswordSecret(for: identity)
            guard password != nil else {
                throw TermindSSHError.proxyAuthentication(
                    hostID: ownerHostID, serverChallenge: false,
                    message: String(localized: "The proxy password is unavailable."))
            }
        }
        return TerminalTransportProxy(
            kind: proxy.kind, hostname: proxy.hostname, port: proxy.port,
            username: proxy.username, password: password,
            identityID: proxy.identityID, ownerHostID: ownerHostID)
    }

    public func prepareSSHConnection(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission] = [:],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    ) throws -> SSHConnectionPreparation {
        guard let route = validatedRoute(for: host) else {
            throw TermindSSHError.route(String(localized: "The Jump Host route is invalid or exceeds eight hosts."))
        }
        return try prepareSSHConnection(
            for: SSHConnectionRoute(hosts: route), submissions: submissions,
            proxySubmissions: proxySubmissions, temporaryHostKeys: temporaryHostKeys)
    }

    public func prepareSSHConnection(
        for route: SSHConnectionRoute, submissions: [Host.ID: SSHAuthenticationSubmission],
        proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission] = [:]
    ) throws -> SSHConnectionPreparation {
        try prepareSSHConnection(
            for: route, submissions: submissions, proxySubmissions: proxySubmissions,
            temporaryHostKeys: [:])
    }

    public func prepareSSHConnection(
        for route: SSHConnectionRoute, submissions: [Host.ID: SSHAuthenticationSubmission],
        proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission] = [:],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    ) throws -> SSHConnectionPreparation {
        guard route.isValid else { throw SSHConnectionRoute.invalidRouteError }
        for node in route.hosts { try requireHostAccess(node) }
        for id in route.sourceHostIDs.values {
            if let source = host(id) { try requireHostAccess(source) }
        }
        let submissions = route.submissions(merging: submissions)
        var preparation = SSHConnectionPreparation(
            nodes: try route.hosts.map { node in
                if node.isTailscaleManaged {
                    var prepared = SSHConnectionPreparation.Node(
                        host: node, identity: nil, key: nil, submission: nil, trustedKeys: [], proxyIdentity: nil)
                    prepared.network = try tailscaleNetwork(for: node)
                    prepared.tailscaleUsername = submissions[node.id]?.username ?? tailscaleUsername(for: node)
                    return prepared
                }
                let submission = submissions[node.id]
                let identity = submission?.identityID.flatMap { self.identity($0) } ?? identity(for: node)
                let keyID = submission != nil ? submission?.keyID : identity?.keyID
                var prepared = SSHConnectionPreparation.Node(
                    host: node, identity: identity,
                    key: keyID.flatMap { key($0) },
                    submission: submission,
                    trustedKeys: Set(knownHosts(for: node).map(\.identity))
                        .union(temporaryHostKeys[node.id].map { [$0] } ?? []),
                    proxyIdentity: (proxySubmissions[node.id]?.identityID ?? node.proxy?.identityID)
                        .flatMap { self.identity($0) },
                    proxySubmission: proxySubmissions[node.id]
                )
                prepared.network = try tailscaleNetwork(for: node)
                return prepared
            },
            secrets: keychain
        )
        preparation.accessHostIDs = route.hosts.map(\.id) + Array(route.sourceHostIDs.values)
        preparation.accessCheck = connectionAccessCheck(for: preparation.accessHostIDs)
        preparation.beforeConnect = connectionWakeAction(for: preparation.accessHostIDs)
        return preparation
    }

    public func sshConnectionConfiguration(
        for host: Host,
        submissions: [Host.ID: SSHAuthenticationSubmission] = [:],
        proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission] = [:],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity] = [:],
        trustPolicy: SSHHostTrustPolicy = .requireKnownHost
    ) throws -> SSHConnectionConfiguration {
        try requireHostAccess(host)
        if host.isTailscaleManaged {
            let username = (submissions[host.id]?.username ?? tailscaleUsername(for: host))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else { throw TailscaleConfigurationError.unavailable }
            var configuration = SSHConnectionConfiguration(
                hostID: host.id, host: host.host, port: 22, username: username,
                credentials: [], expectedHostKeys: [], charset: host.charset,
                authenticationReference: SSHAuthenticationReference(username: username, permitsNone: true)
            )
            configuration.accessCheck = connectionAccessCheck(for: [host.id])
            configuration.beforeConnect = connectionWakeAction(for: [host.id])
            configuration.network = try tailscaleNetwork(for: host)
            configuration.tailscaleNodeID = host.tailscale?.stableNodeID
            return configuration
        }
        let username: String
        let credentials: [SSHCredentials]
        if let submission = submissions[host.id] {
            username = submission.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else { throw TermindSSHError.missingUsername }
            credentials = try sshCredentials(for: submission)
        } else {
            guard let identity = identity(for: host) else {
                throw TermindSSHError.missingCredential
            }
            username = identity.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else { throw TermindSSHError.missingUsername }
            let resolution = sshCredentials(for: identity)
            guard resolution.requiredPassphraseKeyID == nil else {
                throw TermindSSHError.keyPassphraseRequired
            }
            credentials = resolution.credentials
        }
        let expectsCredential =
            submissions[host.id].map { $0.keyID != nil || $0.hasPassword }
            ?? (identity(for: host)?.hasSecret == true)
        if credentials.isEmpty, expectsCredential { throw TermindSSHError.missingCredential }
        let expectedHostKeys = try expectedHostKeys(
            for: host, temporaryHostKeys: temporaryHostKeys,
            trustPolicy: trustPolicy
        )

        var configuration = SSHConnectionConfiguration(
            hostID: host.id, host: host.host, port: host.port, username: username,
            credentials: credentials,
            expectedHostKeys: expectedHostKeys,
            proxy: try transportProxy(for: host, submission: proxySubmissions[host.id]),
            jumps: try sshJumpConfigurations(
                for: host, submissions: submissions, proxySubmissions: proxySubmissions,
                temporaryHostKeys: temporaryHostKeys,
                trustPolicy: trustPolicy
            ),
            charset: host.charset,
            authenticationReference: additionalAuthenticationReference(
                host: host, submission: submissions[host.id]
            )
        )
        configuration.accessCheck = connectionAccessCheck(for: route(for: host).map(\.id))
        configuration.beforeConnect = connectionWakeAction(for: route(for: host).map(\.id))
        configuration.network = try tailscaleNetwork(for: route(for: host).first ?? host)
        return configuration
    }

    public func sshJumpConfigurations(
        for host: Host,
        submissions: [Host.ID: SSHAuthenticationSubmission],
        proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission] = [:],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity] = [:],
        trustPolicy: SSHHostTrustPolicy = .requireKnownHost
    ) throws -> [SSHRouteHopConfiguration] {
        guard let route = validatedRoute(for: host) else {
            throw TermindSSHError.route(String(localized: "The Jump Host route is invalid or exceeds eight hosts."))
        }
        return try sshJumpConfigurations(
            route: route, submissions: submissions, proxySubmissions: proxySubmissions,
            temporaryHostKeys: temporaryHostKeys,
            trustPolicy: trustPolicy
        )
    }

    public func sshJumpConfigurations(
        for route: SSHConnectionRoute, submissions: [Host.ID: SSHAuthenticationSubmission],
        proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission] = [:],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity] = [:],
        trustPolicy: SSHHostTrustPolicy = .requireKnownHost
    ) throws -> [SSHRouteHopConfiguration] {
        guard route.isValid else { throw SSHConnectionRoute.invalidRouteError }
        for node in route.hosts { try requireHostAccess(node) }
        for id in route.sourceHostIDs.values {
            if let source = host(id) { try requireHostAccess(source) }
        }
        return try sshJumpConfigurations(
            route: route.hosts, submissions: route.submissions(merging: submissions),
            proxySubmissions: proxySubmissions,
            temporaryHostKeys: temporaryHostKeys, trustPolicy: trustPolicy
        )
    }

    private func sshJumpConfigurations(
        route: [Host], submissions: [Host.ID: SSHAuthenticationSubmission],
        proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity], trustPolicy: SSHHostTrustPolicy
    ) throws -> [SSHRouteHopConfiguration] {
        return try route.dropLast().enumerated().map { offset, jump in
            do {
                if let submission = submissions[jump.id] {
                    return try sshRouteHopConfiguration(
                        for: jump, submission: submission,
                        proxySubmission: proxySubmissions[jump.id],
                        temporaryHostKeys: temporaryHostKeys,
                        trustPolicy: trustPolicy
                    )
                }
                return try sshRouteHopConfiguration(
                    for: jump, proxySubmission: proxySubmissions[jump.id],
                    temporaryHostKeys: temporaryHostKeys,
                    trustPolicy: trustPolicy
                )
            } catch {
                if (error as? TermindSSHError)?.isProxyAuthentication == true { throw error }
                let authentication =
                    switch error as? TermindSSHError {
                    case .missingCredential, .missingUsername, .keyPassphraseRequired: true
                    default: false
                    }
                let hostKey =
                    switch error as? TermindSSHError {
                    case .untrustedHost: true
                    default: false
                    }
                throw TermindSSHError.routeHost(
                    hostID: jump.id, authentication: authentication,
                    serverChallenge: false, hostKey: hostKey,
                    message: String(localized: "Jump Host \(offset + 1) (\(jump.name)): \(error.localizedDescription)")
                )
            }
        }
    }

    private func sshRouteHopConfiguration(
        for host: Host, proxySubmission: SSHProxyAuthenticationSubmission?,
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity],
        trustPolicy: SSHHostTrustPolicy
    ) throws -> SSHRouteHopConfiguration {
        guard let identity = identity(for: host) else { throw TermindSSHError.missingCredential }
        let username = identity.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { throw TermindSSHError.missingUsername }
        let expectedHostKeys = try expectedHostKeys(
            for: host, temporaryHostKeys: temporaryHostKeys,
            trustPolicy: trustPolicy
        )
        let resolution = sshCredentials(for: identity)
        guard resolution.requiredPassphraseKeyID == nil else {
            throw TermindSSHError.keyPassphraseRequired
        }
        guard !identity.hasSecret || !resolution.credentials.isEmpty else { throw TermindSSHError.missingCredential }
        return SSHRouteHopConfiguration(
            id: host.id, name: host.name, host: host.host, port: host.port,
            username: username, credentials: resolution.credentials,
            expectedHostKeys: expectedHostKeys,
            proxy: try transportProxy(for: host, submission: proxySubmission),
            authenticationReference: additionalAuthenticationReference(
                host: host, submission: nil
            )
        )
    }

    private func sshRouteHopConfiguration(
        for host: Host, submission: SSHAuthenticationSubmission,
        proxySubmission: SSHProxyAuthenticationSubmission?,
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity],
        trustPolicy: SSHHostTrustPolicy
    ) throws -> SSHRouteHopConfiguration {
        let username = submission.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { throw TermindSSHError.missingUsername }
        let expectedHostKeys = try expectedHostKeys(
            for: host, temporaryHostKeys: temporaryHostKeys,
            trustPolicy: trustPolicy
        )
        let credentials = try sshCredentials(for: submission)
        guard submission.keyID == nil || !credentials.isEmpty else { throw TermindSSHError.missingCredential }
        return SSHRouteHopConfiguration(
            id: host.id, name: host.name, host: host.host, port: host.port,
            username: username, credentials: credentials,
            expectedHostKeys: expectedHostKeys,
            proxy: try transportProxy(for: host, submission: proxySubmission),
            authenticationReference: additionalAuthenticationReference(
                host: host, submission: submission
            )
        )
    }

    private func additionalAuthenticationReference(
        host: Host, submission: SSHAuthenticationSubmission?
    ) -> SSHAuthenticationReference {
        let resolvedIdentity =
            submission?.identityID.flatMap(identity)
            ?? (submission == nil ? identity(for: host) : nil)
        if let resolvedIdentity {
            return SSHAuthenticationReference(
                identityID: resolvedIdentity.id,
                username: resolvedIdentity.username,
                permitsNone: !resolvedIdentity.hasSecret,
                hasEphemeralSecret: submission?.hasPassword == true
                    || submission?.hasPassphrase == true
            )
        }
        return SSHAuthenticationReference(
            fallbackKeyID: submission?.keyID,
            username: submission?.username ?? "",
            permitsNone: submission?.keyID == nil && submission?.hasPassword != true,
            hasEphemeralSecret: submission?.hasPassword == true
                || submission?.hasPassphrase == true
        )
    }

    private func sshCredentials(for submission: SSHAuthenticationSubmission) throws -> [SSHCredentials] {
        var credentials: [SSHCredentials] = []
        if let keyID = submission.keyID, let key = key(keyID) {
            if requiresPassphraseEntry(for: key), !submission.hasPassphrase {
                throw TermindSSHError.keyPassphraseRequired
            }
            if let stored = try keySecretCredential(for: key) {
                credentials.append(
                    stored.sshCredential(
                        for: key, passphraseOverride: submission.passphraseForConnection()
                    )
                )
            }
        }
        if let password = submission.passwordForConnection() {
            credentials.append(.password(password))
        } else if let identityID = submission.identityID,
            let identity = identity(identityID), identity.usesPassword,
            let password = try passwordSecret(for: identity)
        {
            credentials.append(.password(password))
        }
        return credentials
    }

    public func transportProxy(
        for host: Host, submission: SSHProxyAuthenticationSubmission?
    ) throws -> SSHTransportProxy? {
        guard let proxy = host.proxy else { return nil }
        guard proxy.isValid else {
            throw TermindSSHError.proxy(String(localized: "The proxy configuration is incomplete."))
        }
        var password = submission?.passwordForConnection()
        if password == nil, let identityID = submission?.identityID ?? proxy.identityID {
            guard let identity = identity(identityID), identity.usesPassword else {
                throw TermindSSHError.proxyAuthentication(
                    hostID: host.id, serverChallenge: false,
                    message: String(localized: "The proxy password identity is unavailable."))
            }
            do {
                password = try passwordSecret(for: identity)
            } catch {
                throw TermindSSHError.proxyAuthentication(
                    hostID: host.id, serverChallenge: false, message: error.localizedDescription)
            }
            guard password != nil else {
                throw TermindSSHError.proxyAuthentication(
                    hostID: host.id, serverChallenge: false,
                    message: String(localized: "The proxy password is unavailable."))
            }
        }
        return SSHTransportProxy(
            kind: proxy.kind, hostname: proxy.hostname, port: proxy.port,
            username: submission?.username ?? proxy.username, password: password,
            identityID: submission?.identityID ?? proxy.identityID,
            ownerHostID: host.id
        )
    }

    /// Loads Key and Password independently so one damaged or missing Keychain
    /// item does not suppress the other usable credential.
    public func sshCredentials(for identity: Identity) -> SSHCredentialResolution {
        var credentials: [SSHCredentials] = []
        var failures: [String] = []
        var requiredPassphraseKeyID: SSHKeyRef.ID?

        if let keyID = identity.keyID {
            if let key = key(keyID) {
                if requiresPassphraseEntry(for: key) {
                    requiredPassphraseKeyID = key.id
                } else {
                    do {
                        if let credential = try keySecretCredential(for: key) {
                            credentials.append(
                                credential.sshCredential(
                                    for: key
                                )
                            )
                        } else {
                            failures.append(
                                String(localized: "The selected key has no saved private key.")
                            )
                        }
                    } catch {
                        storageError = error.localizedDescription
                        failures.append(error.localizedDescription)
                    }
                }
            } else {
                failures.append(
                    String(localized: "The selected key is no longer available.")
                )
            }
        }

        if identity.usesPassword {
            do {
                if let password = try passwordSecret(for: identity) {
                    credentials.append(.password(password))
                } else {
                    failures.append(
                        String(localized: "The saved password is no longer available.")
                    )
                }
            } catch {
                storageError = error.localizedDescription
                failures.append(error.localizedDescription)
            }
        }

        return SSHCredentialResolution(
            credentials: credentials, failures: failures,
            hasConfiguredCredential: identity.hasSecret,
            requiredPassphraseKeyID: requiredPassphraseKeyID
        )
    }

    /// Every host tag, deduplicated case-insensitively and sorted.
    public var allTags: [String] {
        uniqueSortedTags(hosts.flatMap(\.tags))
    }

    /// Tags in use on hosts. What the Hosts page offers to filter by: a
    /// snippet-only tag there would be a filter that matches nothing.
    public var hostTags: [String] {
        uniqueSortedTags(hosts.flatMap(\.tags))
    }

    private func uniqueSortedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        let uniqueTags = tags.filter { seen.insert($0.lowercased()).inserted }
        return uniqueTags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Search

    /// Also matches the resolved identity, so filtering by `deploy` still finds
    /// every box that logs in as `deploy` now that the name lives one hop away.
    public func searchHosts(_ query: String) -> [Host] {
        hosts
            .filter { host in
                host.matches(query)
                    || host.supportedTerminalProtocols.contains {
                        loginAddress(for: host, protocol: $0).localizedCaseInsensitiveContains(query)
                    }
                    || (!query.isEmpty
                        && host.supportedTerminalProtocols.contains {
                            identity(for: host, protocol: $0)?.matches(query) == true
                        })
            }
            .sorted { $0.name < $1.name }
    }

    public func hosts(matching query: String, requiring requirement: HostProtocolRequirement) -> [Host] {
        searchHosts(query).filter { $0.supports(requirement) }
    }

    public func hosts(matching query: String, for useCase: HostUseCase) -> [Host] {
        hosts(matching: query, requiring: useCase.protocolRequirement).filter { isEligible($0, for: useCase) }
    }

    public func isEligible(_ host: Host, for useCase: HostUseCase) -> Bool {
        guard (try? requireHostAccess(host, protocol: useCase.accessProtocol(for: host))) != nil else { return false }
        if host.isTailscaleManaged && [.jumpHost, .keyExport, .portForwarding].contains(useCase) { return false }
        return host.supports(useCase.protocolRequirement)
    }

    public func require(_ host: Host, for useCase: HostUseCase) throws {
        try requireHostAccess(host, protocol: useCase.accessProtocol(for: host))
        guard isEligible(host, for: useCase) else {
            throw HostProtocolUnavailableError(useCase: useCase)
        }
    }

    public func searchSnippets(_ query: String) -> [Snippet] {
        snippets.filter {
            $0.matches(query)
                || (!query.isEmpty
                    && snippetPackagePath($0.packageID)?.localizedCaseInsensitiveContains(query) == true)
        }.sorted { $0.sortIndex < $1.sortIndex }
    }

    public func searchKeys(_ query: String) -> [SSHKeyRef] {
        keys
            .filter { key in
                query.isEmpty
                    || key.label.localizedCaseInsensitiveContains(query)
                    || key.fingerprint.localizedCaseInsensitiveContains(query)
            }
            .sorted { manuallyOrdered($0.sortIndex, $0.label, $1.sortIndex, $1.label) }
    }

    public func searchIdentities(_ query: String) -> [Identity] {
        reusableIdentities.filter { $0.matches(query) }.sorted {
            manuallyOrdered($0.sortIndex, $0.name, $1.sortIndex, $1.name)
        }
    }

    // MARK: - Writes

    @discardableResult
    public func duplicateHost(_ proposed: Host, name: String) async throws -> Bool {
        guard let source = host(proposed.id), !source.isTailscaleManaged else { return false }
        var copy = source
        if source.identityID.flatMap(identity)?.isHostCustom == true { copy.identityID = nil }
        if source.telnetIdentityID.flatMap(identity)?.isHostCustom == true { copy.telnetIdentityID = nil }
        if source.proxy?.identityID.flatMap(identity)?.isHostCustom == true {
            copy.proxy?.identityID = nil
            copy.proxy?.username = ""
        }
        if source.telnetProxy?.identityID.flatMap(identity)?.isHostCustom == true {
            copy.telnetProxy?.identityID = nil
            copy.telnetProxy?.username = ""
        }
        copy.id = UUID()
        copy.name = name
        copy.createdAt = nil
        try await resolveSavingHostsAccess([copy])
        try Task.checkCancellation()
        guard host(source.id) != nil else { return false }
        return saveHost(copy)
    }

    public func upsert(_ host: Host) { _ = saveHost(host) }

    @discardableResult
    public func saveHost(_ host: Host) -> Bool {
        guard host.wakeOnLAN.isValid else {
            storageError = WakeOnLANError.invalidAddress.localizedDescription
            return false
        }
        do { try requireSavingHosts([host]) } catch HostAccessError.hostLimit {
            storageError = nil
            return false
        } catch {
            storageError = error.localizedDescription
            return false
        }
        if self.host(host.id)?.isTailscaleManaged == true || host.isTailscaleManaged {
            return saveTailscaleHost(host)
        }
        var host = host
        host.createdAt = self.host(host.id)?.createdAt ?? (self.host(host.id) == nil ? .now : nil)
        host.name = SavedName.resolve(host.name, default: host.defaultName)
        host.portForwardingMaxConnections = Host.normalizedPortForwardingMaxConnections(
            host.portForwardingMaxConnections)
        guard host.preferredTerminalProtocol != nil else {
            storageError = String(localized: "Enable SSH or Telnet before saving this Host.")
            return false
        }
        guard !host.sshEnabled || (1...65_535).contains(host.sshPort),
            !host.telnetEnabled || (1...65_535).contains(host.telnetPort)
        else {
            storageError = String(localized: "The enabled protocol port must be between 1 and 65535.")
            return false
        }
        guard !host.sshEnabled || validatedRoute(for: host) != nil else {
            storageError = String(localized: "The selected jump host creates a routing loop or exceeds 8 hops.")
            return false
        }
        let previous = hosts
        let old = self.host(host.id)
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            var updated = host
            updated.detectedDistribution = hosts[index].detectedDistribution
            hosts[index] = updated
        } else {
            var new = host
            new.sortIndex = nextSortIndex(in: host.groupID)
            hosts.append(new)
        }
        guard persistCore() else {
            hosts = previous
            return false
        }
        if let old {
            if !old.hasSameSSHConnectionRoute(as: host) { didChangeHostConnection?(host.id) }
            if !old.hasSameTelnetConnection(as: host) { didChangeTelnetConnection?(host.id) }
        }
        return true
    }

    /// Transitional in-memory projection for repository-owned durable deletion.
    /// The repository is the only writer; this keeps legacy views in sync until
    /// they consume `HostLibraryModel` directly.
    public func projectHostDeletion(_ hostID: Host.ID) {
        guard host(hostID)?.isTailscaleManaged != true else { return }
        let owned = identities.filter { $0.ownerHostID == hostID }
        for identity in owned where !identity.credentialRef.isEmpty {
            do {
                try removePassword(identity.credentialRef, storage: identity.passwordStorage)
            } catch {
                storageError = error.localizedDescription
            }
        }
        identities.removeAll { $0.ownerHostID == hostID }
        removeHostProjection(hostID)
    }

    private func removeHostProjection(_ hostID: Host.ID) {
        hosts.removeAll { $0.id == hostID }
        for index in hosts.indices where hosts[index].jumpHostID == hostID {
            hosts[index].jumpHostID = nil
        }
        for index in snippets.indices {
            snippets[index].targetHostIDs.removeAll { $0 == hostID }
        }
        portForwardings.removeAll { $0.hostID == hostID }
        connectionStatuses = connectionStatuses.filter { $0.value.hostID != hostID }
        statuses[hostID] = nil
    }

    public func setStatus(_ status: ConnectionStatus, for id: Host.ID) {
        statuses[id] = status
    }

    /// Records one live connection's state for Host-level consumers, including
    /// the Vault and Recents dots and the agent Host listing. A connected source
    /// wins over a connecting or failed sibling, so closing one pane cannot make
    /// an otherwise-online Host appear offline.
    public func setConnectionStatus(
        _ status: ConnectionStatus, connectionID: UUID, hostID: Host.ID
    ) {
        if status == .disconnected {
            connectionStatuses[connectionID] = nil
        } else {
            connectionStatuses[connectionID] = (hostID, status)
        }
        refreshStatus(for: hostID)
    }

    /// Persists only a meaningful, validated distribution transition. The
    /// current Host projection is mutated in place so a shell result cannot
    /// overwrite editor changes made while the connection was starting.
    public func recordRemoteSystemInfo(_ systemInfo: RemoteSystemInfo?, for hostID: Host.ID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }),
            let systemInfo,
            case .resolved(let next) = systemInfo.distributionDetection
        else { return }

        guard hosts[index].detectedDistribution != next else { return }
        if hosts[index].isTailscaleManaged {
            guard let groupIndex = groups.firstIndex(where: { $0.id == hosts[index].groupID }),
                groups[groupIndex].tailscale != nil
            else { return }
            let previous = groups
            var preferences = groups[groupIndex].tailscale!.hostPreferences[hostID] ?? TailscaleHostPreferences()
            preferences.detectedDistribution = next
            groups[groupIndex].tailscale!.hostPreferences[hostID] = preferences
            guard persistCore() else {
                groups = previous
                return
            }
            rebuildTailscaleHosts()
        } else {
            hosts[index].detectedDistribution = next
            persistCore()
        }
    }

    private func refreshStatus(for hostID: Host.ID) {
        let active = connectionStatuses.values
            .filter { $0.hostID == hostID }
            .map(\.status)
        if active.contains(.connected) {
            statuses[hostID] = .connected
        } else if active.contains(.reconnecting) {
            statuses[hostID] = .reconnecting
        } else if active.contains(.connecting) {
            statuses[hostID] = .connecting
        } else if let failure = active.first(where: {
            if case .failed = $0 { return true }
            return false
        }) {
            statuses[hostID] = failure
        } else {
            statuses[hostID] = nil
        }
    }

    /// Drops a pinned host key. The next connection to that host is treated as a
    /// first connection, which is the whole point — it is the escape hatch for a
    /// server that was legitimately rekeyed.
    public func forget(knownHost id: KnownHostEntry.ID) {
        deleteKnownHosts([id])
    }

    public func forgetKnownHosts(for host: Host) {
        deleteKnownHosts(Set(knownHosts(for: host).map(\.id)))
    }

    public func trust(_ entry: KnownHostEntry) {
        let endpointMatches: (KnownHostEntry) -> Bool = {
            $0.matches(hostname: entry.hostname, port: entry.port)
        }
        if let index = knownHosts.firstIndex(where: {
            endpointMatches($0) && $0.fingerprint == entry.fingerprint
        }) {
            let retainedID = knownHosts[index].id
            knownHosts[index].algorithm = entry.algorithm
            knownHosts[index].addedAt = entry.addedAt
            knownHosts.removeAll {
                $0.id != retainedID && endpointMatches($0)
                    && $0.fingerprint == entry.fingerprint
            }
        } else {
            knownHosts.append(entry)
        }
        persistCore()
    }

    public func setExpanded(_ expanded: Bool, for groupID: HostGroup.ID) {
        guard group(groupID) != nil else { return }
        expansionState.setHostGroupExpanded(expanded, for: groupID)
    }

    public func setUngroupedExpanded(_ expanded: Bool) {
        expansionState.setHostsUngroupedExpanded(expanded)
    }

    public func setSnippetPackageExpanded(_ expanded: Bool, for packageID: SnippetPackage.ID) {
        guard snippetPackage(packageID) != nil else { return }
        expansionState.setSnippetPackageExpanded(expanded, for: packageID)
    }

    public func setSnippetsUngroupedExpanded(_ expanded: Bool) {
        expansionState.setSnippetsUngroupedExpanded(expanded)
    }

    /// Adds or updates an identity. New ones land at the end of the list, which
    /// is sorted by name wherever it is shown, so there is no order to keep.
    @discardableResult
    public func upsert(_ identity: Identity) -> Bool {
        upsert(identity, touchingModificationDate: false)
    }

    @discardableResult
    private func upsert(_ identity: Identity, touchingModificationDate: Bool) -> Bool {
        var identity = identity
        identity.name = SavedName.resolve(identity.name, default: identity.defaultName)
        if let previous = self.identity(identity.id),
            previous.usesPassword,
            previous.passwordStorage == .iCloud,
            identity.passwordStorage == .thisDevice
        {
            storageError = String(localized: "iCloud credentials cannot be moved to This Device.")
            return false
        }
        let identitySnapshot = identities
        let hostSnapshot = hosts
        if let index = identities.firstIndex(where: { $0.id == identity.id }) {
            let previous = identities[index]
            var updated = identity
            updated.sortIndex = previous.sortIndex
            identities[index] = updated
        } else {
            var new = identity
            new.sortIndex = (identities.map(\.sortIndex).max() ?? -1) + 1
            identities.append(new)
        }
        if !identity.isProxyEligible {
            for index in hosts.indices where hosts[index].proxy?.identityID == identity.id {
                hosts[index].proxy?.identityID = nil
                hosts[index].proxy?.username = ""
            }
        }
        let touchedKeys: Set<VaultRecordKey> =
            touchingModificationDate
            ? [VaultRecordKey(kind: .identity, id: identity.id)]
            : []
        let saved = persistCore(touching: touchedKeys)
        if !saved {
            identities = identitySnapshot
            hosts = hostSnapshot
        }
        return saved
    }

    /// Commit the destination's private login and host reference together. Reusable
    /// identities (and their password references) are never changed by an export.
    public func attachExportedKey(_ keyID: SSHKeyRef.ID, to hostID: Host.ID, username: String) throws {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }), key(keyID) != nil,
            isEligible(hosts[index], for: .keyExport), !username.isEmpty
        else { throw TermindSSHError.missingCredential }
        let host = hosts[index]
        let source = identity(for: host)
        let owned = customIdentity(for: hostID, purpose: .ssh)
        var destination =
            owned ?? Identity(name: host.name, username: username, ownerHostID: hostID, customPurpose: .ssh)
        destination.username = username
        destination.keyID = keyID
        var copiedReference: String?
        if source?.id != owned?.id || owned == nil {
            destination.credentialRef = ""
            if let source, source.usesPassword {
                guard let password = try editablePassword(for: source) else {
                    throw TermindSSHError.missingCredential
                }
                let reference = "termind.password.\(UUID().uuidString)"
                destination.passwordStorage = source.passwordStorage
                try setPasswordString(password, for: reference, storage: destination.passwordStorage)
                destination.credentialRef = reference
                copiedReference = reference
            }
        }
        let previousIdentities = identities
        let previousHosts = hosts
        if let identityIndex = identities.firstIndex(where: { $0.id == destination.id }) {
            identities[identityIndex] = destination
        } else {
            identities.append(destination)
        }
        hosts[index].sshIdentityID = destination.id
        guard persistCore() else {
            identities = previousIdentities
            hosts = previousHosts
            if let copiedReference {
                try removePassword(copiedReference, storage: destination.passwordStorage)
            }
            throw TermindSSHError.library(storageError ?? String(localized: "Unable to Save"))
        }
        if let owned, !owned.credentialRef.isEmpty, owned.credentialRef != destination.credentialRef {
            try? removePassword(owned.credentialRef, storage: owned.passwordStorage)
        }
        didChangeHostConnection?(hostID)
    }

    /// Updates an Identity and its Keychain password as one operation.
    ///
    /// The editor supplies intent rather than an optional string so a blank
    /// field can keep an existing password while an explicit remove action can
    /// delete it. The old reference is resolved here, before the model changes,
    /// which prevents a cleared Identity from making its former Keychain item
    /// unreachable.
    public func upsert(_ identity: Identity, passwordUpdate: IdentityPasswordUpdate) throws {
        let previousIdentity = self.identity(identity.id)
        let previousReference = previousIdentity?.credentialRef ?? identity.credentialRef
        let previousStorage = previousIdentity?.passwordStorage ?? identity.passwordStorage
        var updated = identity

        if previousIdentity?.usesPassword == true,
            previousStorage == .iCloud,
            updated.passwordStorage == .thisDevice
        {
            throw TermindSSHError.library(
                String(localized: "iCloud credentials cannot be moved to This Device.")
            )
        }

        var oldPassword: String?
        func loadOldPassword() throws -> String? {
            if let oldPassword { return oldPassword }
            guard !previousReference.isEmpty else { return nil }
            let loaded = try keychain.string(for: previousReference, storage: previousStorage)
            oldPassword = loaded
            return loaded
        }
        let identitySnapshot = identities
        let hostSnapshot = hosts
        var wroteDestination = false
        do {
            switch passwordUpdate {
            case .keep:
                updated.credentialRef = previousReference
                if previousStorage != updated.passwordStorage, !previousReference.isEmpty {
                    guard let oldPassword = try loadOldPassword() else {
                        throw TermindSSHError.library(
                            String(
                                localized:
                                    "The saved password is unavailable on this Mac. Enter it again before changing storage."
                            )
                        )
                    }
                    try setPasswordString(
                        oldPassword, for: previousReference, storage: updated.passwordStorage
                    )
                    wroteDestination = true
                }
            case .replace(let password):
                guard !password.isEmpty else {
                    throw TermindSSHError.library(
                        String(localized: "A replacement password cannot be empty.")
                    )
                }
                let reference =
                    previousReference.isEmpty
                    ? "termind.password.\(UUID().uuidString)"
                    : previousReference
                _ = try loadOldPassword()
                try setPasswordString(password, for: reference, storage: updated.passwordStorage)
                wroteDestination = true
                updated.credentialRef = reference
            case .remove:
                updated.credentialRef = ""
            }
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            throw error
        }

        let changesPassword: Bool
        switch passwordUpdate {
        case .keep: changesPassword = false
        case .replace, .remove: changesPassword = true
        }
        guard upsert(updated, touchingModificationDate: changesPassword) else {
            identities = identitySnapshot
            hosts = hostSnapshot
            do {
                if wroteDestination {
                    if updated.passwordStorage == previousStorage, let oldPassword {
                        try setPasswordString(
                            oldPassword, for: previousReference, storage: previousStorage
                        )
                    } else if !updated.credentialRef.isEmpty {
                        try removePassword(
                            updated.credentialRef, storage: updated.passwordStorage
                        )
                    }
                }
            } catch {
                storageError = String(
                    localized: "The database save and Keychain rollback both failed: \(error.localizedDescription)"
                )
            }
            throw TermindSSHError.library(
                storageError ?? String(localized: "The identity could not be saved.")
            )
        }
        let removesPrevious =
            !previousReference.isEmpty
            && (updated.credentialRef.isEmpty || previousStorage != updated.passwordStorage)
        if removesPrevious {
            do {
                try removePassword(previousReference, storage: previousStorage)
            } catch {
                // The newly committed destination stays authoritative. Retaining
                // the source is safer than rolling a successful save backward.
                storageError = String(
                    localized:
                        "The password was saved, but its previous Keychain copy could not be removed: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Throwing counterpart used by connection setup, where a Keychain failure
    /// must remain distinguishable from an Identity that has no password.
    public func passwordCredential(for identity: Identity) throws -> String? {
        guard identity.usesPassword else { return nil }
        return try keychain.string(
            for: identity.credentialRef, storage: identity.passwordStorage
        )
    }

    public func editablePassword(for identity: Identity) throws -> String? {
        try passwordCredential(for: identity)
    }

    @discardableResult
    public func saveCustomIdentity(
        ownerHostID: Host.ID, purpose: HostCustomIdentityPurpose, displayName: String,
        username: String, password: String, keyID: SSHKeyRef.ID?
    ) throws -> Identity? {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = customIdentity(for: ownerHostID, purpose: purpose)
        if username.isEmpty && password.isEmpty && keyID == nil {
            if let existing, !delete(identityID: existing.id) {
                throw TermindSSHError.library(
                    storageError ?? String(localized: "The identity could not be saved."))
            }
            return nil
        }

        var value = Identity(
            id: existing?.id ?? UUID(), name: displayName, username: username,
            credentialRef: existing?.credentialRef ?? "",
            passwordStorage: existing?.passwordStorage ?? customPasswordStorage,
            keyID: purpose == .ssh ? keyID : nil, notes: existing?.notes ?? "",
            colorTag: existing?.colorTag ?? .none,
            sortIndex: existing?.sortIndex ?? 0, ownerHostID: ownerHostID, customPurpose: purpose
        )
        let update: IdentityPasswordUpdate
        if let existing, passwordAvailability(for: existing) != .available {
            update = .keep
        } else {
            let previous = try existing.flatMap { try editablePassword(for: $0) } ?? ""
            update = password == previous ? .keep : password.isEmpty ? .remove : .replace(password)
        }
        try upsert(value, passwordUpdate: update)
        value = identity(value.id) ?? value
        return value
    }

    public var customPasswordStorage: PasswordStorage {
        let cloud =
            defaults.object(forKey: SettingsKey.iCloudSyncEnabled) as? Bool
            ?? SettingsKey.defaultICloudSyncEnabled
        return cloud ? .iCloud : .thisDevice
    }

    /// One-way migration for Host-private passwords when Vault sync becomes active.
    /// The local copy is removed only after the iCloud value is verified and the
    /// Identity metadata has committed successfully.
    public func migrateCustomPasswordsToICloud() throws {
        guard customPasswordStorage == .iCloud else { return }
        for identity in identities where identity.isHostCustom && identity.passwordStorage == .thisDevice {
            var updated = identity
            if identity.credentialRef.isEmpty {
                updated.passwordStorage = .iCloud
                guard upsert(updated) else {
                    throw TermindSSHError.library(
                        storageError ?? String(localized: "The identity could not be saved."))
                }
                continue
            }
            guard let password = try keychain.string(for: identity.credentialRef, storage: .thisDevice) else {
                throw TermindSSHError.library(String(localized: "The saved password is no longer available."))
            }
            try setPasswordString(password, for: identity.credentialRef, storage: .iCloud)
            guard try keychain.string(for: identity.credentialRef, storage: .iCloud) == password else {
                try? removePassword(identity.credentialRef, storage: .iCloud)
                throw TermindSSHError.library(String(localized: "The saved password is no longer available."))
            }
            updated.passwordStorage = .iCloud
            guard upsert(updated) else {
                try? removePassword(identity.credentialRef, storage: .iCloud)
                throw TermindSSHError.library(
                    storageError ?? String(localized: "The identity could not be saved."))
            }
            try removePassword(identity.credentialRef, storage: .thisDevice)
        }
    }

    public func passwordSecret(for identity: Identity) throws -> SSHSecret? {
        guard identity.usesPassword else { return nil }
        return try keychain.sshSecret(
            for: identity.credentialRef, storage: identity.passwordStorage
        )
    }

    private func setPasswordString(_ password: String, for reference: String, storage: PasswordStorage) throws {
        try keychain.setString(password, for: reference, storage: storage)
        passwordAvailabilityRevision &+= 1
    }

    private func removePassword(_ reference: String, storage: PasswordStorage) throws {
        try keychain.removePassword(reference, storage: storage)
        if !reference.isEmpty { passwordAvailabilityRevision &+= 1 }
    }

    public func passwordAvailability(for identity: Identity) -> SecretAvailability {
        guard identity.usesPassword else { return .notConfigured }
        do {
            return try keychain.containsString(
                for: identity.credentialRef, storage: identity.passwordStorage
            ) ? .available : .missing
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func isProxyEligibleOnThisDevice(_ identity: Identity) -> Bool {
        identity.isProxyEligible && passwordAvailability(for: identity) == .available
    }

    /// Removes an identity, along with the password it was the only way to
    /// reach, and unfiles it from every host that logged in with it — those
    /// hosts keep their address and go back to "no login chosen yet".
    @discardableResult
    public func delete(identityID: Identity.ID) -> Bool {
        guard let identity = identity(identityID) else { return false }
        let password: String?
        do {
            password =
                identity.credentialRef.isEmpty
                ? nil
                : try keychain.string(
                    for: identity.credentialRef, storage: identity.passwordStorage
                )
            try removePassword(
                identity.credentialRef, storage: identity.passwordStorage
            )
        } catch {
            storageError = error.localizedDescription
            return false
        }
        let identitySnapshot = identities
        let hostSnapshot = hosts
        identities.removeAll { $0.id == identityID }
        for index in hosts.indices where hosts[index].identityID == identityID {
            hosts[index].identityID = nil
        }
        for index in hosts.indices where hosts[index].proxy?.identityID == identityID {
            hosts[index].proxy?.identityID = nil
            hosts[index].proxy?.username = ""
        }
        guard persistCore() else {
            identities = identitySnapshot
            hosts = hostSnapshot
            if let password {
                do {
                    try setPasswordString(
                        password, for: identity.credentialRef,
                        storage: identity.passwordStorage
                    )
                } catch {
                    storageError = String(
                        localized: "The database save and Keychain rollback both failed: \(error.localizedDescription)"
                    )
                }
            }
            return false
        }
        return true
    }

    public func upsert(_ key: SSHKeyRef, credential: StoredSSHKeyCredential? = nil) throws {
        var key = key
        key.label = SavedName.resolve(key.label, default: key.defaultName)
        let previousKey = self.key(key.id)
        if key.algorithm == .securityKey {
            guard credential == nil, let reference = key.securityKey,
                !reference.credentialID.isEmpty, reference.publicKeyX963.count == 65,
                key.certificate.isEmpty, key.storage != .secureEnclave,
                previousKey == nil || previousKey?.algorithm == .securityKey
            else { throw CocoaError(.coderInvalidValue) }
            key.credentialRef = ""
            key.storage = .external
            key.hasPassphrase = false
            key.requiresUserPresence = reference.requiresUserPresence
            let snapshot = keys
            if let index = keys.firstIndex(where: { $0.id == key.id }) {
                key.sortIndex = keys[index].sortIndex
                keys[index] = key
            } else {
                key.sortIndex = (keys.map(\.sortIndex).max() ?? -1) + 1
                keys.append(key)
            }
            guard persistCore() else {
                keys = snapshot
                throw TermindSSHError.library(storageError ?? String(localized: "The key could not be saved."))
            }
            keyCredentialRevision &+= 1
            return
        }
        guard key.securityKey == nil, key.storage != .external else { throw CocoaError(.coderInvalidValue) }
        if previousKey?.storage == .iCloud, key.storage == .thisDevice {
            throw TermindSSHError.library(
                String(localized: "iCloud credentials cannot be moved to This Device.")
            )
        }
        if key.storage == .secureEnclave, !key.certificate.isEmpty {
            throw TermindSSHError.library(
                String(localized: "Secure Enclave keys cannot store an SSH certificate.")
            )
        }
        if !key.certificate.isEmpty {
            _ = try SSHUserCertificate.parse(key.certificate, matching: key.publicKey.isEmpty ? nil : key.publicKey)
        }
        let keySnapshot = keys
        let changesLocation =
            previousKey.map {
                $0.storage != key.storage || $0.credentialRef != key.credentialRef
            } ?? false
        if changesLocation,
            previousKey?.storage == .secureEnclave || key.storage == .secureEnclave
        {
            throw TermindSSHError.library(
                String(localized: "Secure Enclave keys cannot be moved to another storage location.")
            )
        }
        let previousCredential =
            try (credential != nil || changesLocation)
            ? previousKey.flatMap { try keySecretCredential(for: $0) }
            : nil
        let destinationCredential = credential?.resolvedCredential() ?? (changesLocation ? previousCredential : nil)
        defer {
            previousCredential?.clearSecrets()
            destinationCredential?.clearSecrets()
        }
        if let destinationCredential {
            try keychain.setResolvedKeyCredential(
                destinationCredential, for: key.credentialRef, storage: key.storage
            )
        }
        if let index = keys.firstIndex(where: { $0.id == key.id }) {
            var updated = key
            updated.sortIndex = keys[index].sortIndex
            keys[index] = updated
        } else {
            var new = key
            new.sortIndex = (keys.map(\.sortIndex).max() ?? -1) + 1
            keys.append(new)
        }
        guard persistCore() else {
            keys = keySnapshot
            do {
                if changesLocation, destinationCredential != nil {
                    try keychain.removeKeyCredential(
                        key.credentialRef, storage: key.storage
                    )
                } else if destinationCredential != nil, let previousKey, let previousCredential {
                    try keychain.setResolvedKeyCredential(
                        previousCredential, for: previousKey.credentialRef,
                        storage: previousKey.storage
                    )
                } else if destinationCredential != nil {
                    try keychain.removeKeyCredential(key.credentialRef, storage: key.storage)
                }
            } catch {
                storageError = String(
                    localized: "The database save and Keychain rollback both failed: \(error.localizedDescription)"
                )
            }
            throw TermindSSHError.library(
                storageError ?? String(localized: "The key could not be saved.")
            )
        }
        if destinationCredential != nil { keyCredentialRevision &+= 1 }
        if changesLocation, let previousKey {
            do {
                try keychain.removeKeyCredential(
                    previousKey.credentialRef, storage: previousKey.storage
                )
            } catch {
                storageError = String(
                    localized:
                        "The key was saved, but its previous Keychain copy could not be removed: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Reorders Keys without allowing them to leave their fixed Keychain
    /// section. The supplied order is the order of a multi-card drag.
    public func move(keyIDs: [SSHKeyRef.ID], before next: SSHKeyRef.ID? = nil) {
        guard
            reorderManually(
                keyIDs, before: next, items: &keys, sortIndex: \SSHKeyRef.sortIndex
            )
        else { return }
        persistCore()
    }

    /// Reorders Identities independently from Keys. A mixed Keychain selection
    /// is split by the page before it reaches this fixed-section operation.
    public func move(identityIDs: [Identity.ID], before next: Identity.ID? = nil) {
        guard
            reorderManually(
                identityIDs, before: next, items: &identities,
                sortIndex: \Identity.sortIndex
            )
        else { return }
        persistCore()
    }

    public func keyCredential(for key: SSHKeyRef) throws -> StoredSSHKeyCredential? {
        guard key.algorithm != .securityKey else { return nil }
        return try keychain.keyCredential(for: key.credentialRef, storage: key.storage)
    }

    public func saveKeyPassphrase(_ passphrase: String, for keyID: SSHKeyRef.ID) throws {
        guard !passphrase.isEmpty, let key = key(keyID), key.hasPassphrase, key.storage != .secureEnclave else {
            throw TermindSSHError.missingCredential
        }
        let secret = SSHSecret(passphrase)
        defer { secret.clear() }
        try keychain.setKeyPassphrase(secret, for: key.credentialRef, storage: key.storage)
        keyCredentialRevision &+= 1
    }

    public func keySecretCredential(for key: SSHKeyRef) throws -> SSHResolvedKeyCredential? {
        _ = keyCredentialRevision
        return try keychain.sshKeyCredential(for: key)
    }

    public func keyAvailability(for key: SSHKeyRef) -> SecretAvailability {
        if key.algorithm == .securityKey { return key.securityKey == nil ? .missing : .available }
        do {
            return try keychain.containsKeyCredential(
                for: key.credentialRef, storage: key.storage
            ) ? .available : .missing
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func delete(keyID: SSHKeyRef.ID) throws {
        guard let key = key(keyID) else { return }
        let credential = try keySecretCredential(for: key)
        defer { credential?.clearSecrets() }
        if key.algorithm != .securityKey {
            try keychain.removeKeyCredential(key.credentialRef, storage: key.storage)
        }
        let keySnapshot = keys
        let identitySnapshot = identities
        keys.removeAll { $0.id == keyID }
        for index in identities.indices where identities[index].keyID == keyID {
            identities[index].keyID = nil
        }
        guard persistCore() else {
            keys = keySnapshot
            identities = identitySnapshot
            if key.algorithm != .securityKey, let credential {
                try keychain.setResolvedKeyCredential(
                    credential, for: key.credentialRef, storage: key.storage
                )
            }
            throw TermindSSHError.library(
                storageError ?? String(localized: "The key could not be deleted.")
            )
        }
    }

    /// Adds or updates a group. A new group is placed after its last sibling
    /// rather than at the end of the flat array — `sortIndex` is per-parent, so
    /// a child of Production has to be numbered against Production's children.
    public func upsert(_ group: HostGroup) {
        _ = saveGroup(group)
    }

    @discardableResult
    public func saveGroup(_ group: HostGroup) -> Bool {
        let invalidated: Set<UUID> =
            groups.contains {
                $0.id == group.id && $0.tailscale != nil && $0.tailscale?.network != group.tailscale?.network
            } ? [group.id] : []
        let removedManaged = Set(
            hosts.filter { $0.tailscale.map { invalidated.contains($0.groupID) } == true }.map(\.id))
        let previous = groups
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            var new = group
            new.sortIndex = nextSortIndex(under: group.parentID)
            groups.append(new)
        }
        guard persistCore() else {
            groups = previous
            return false
        }
        for id in invalidated { tailscalePeers[id] = nil }
        rebuildTailscaleHosts()
        if !invalidated.isEmpty { didDeleteTailscaleGroups?(invalidated, removedManaged) }
        didChangeTailscaleGroups?()
        return true
    }

    /// Deletes a group and every group beneath it.
    ///
    /// Removes a group subtree after callers have durably requested deletion
    /// for any hosts they do not intend to keep.
    public func deleteGroupProjection(_ groupID: HostGroup.ID) {
        _ = removeGroup(groupID)
    }

    @discardableResult
    public func removeGroup(_ groupID: HostGroup.ID) -> Bool {
        let doomed = Set([groupID] + descendantGroups(of: groupID).map(\.id))
        let tailnets = Set(groups.filter { doomed.contains($0.id) && $0.tailscale != nil }.map(\.id))
        let managed = Set(hosts.filter { $0.tailscale.map { doomed.contains($0.groupID) } == true }.map(\.id))
        let previousHosts = hosts
        let previousGroups = groups
        hosts.removeAll { managed.contains($0.id) }
        for index in hosts.indices where hosts[index].groupID.map(doomed.contains) ?? false {
            hosts[index].groupID = nil
        }
        groups.removeAll { doomed.contains($0.id) }
        guard persistCore() else {
            hosts = previousHosts
            groups = previousGroups
            return false
        }
        for id in doomed { tailscalePeers[id] = nil }
        reconcileExpansionState()
        didDeleteTailscaleGroups?(tailnets, managed)
        didChangeTailscaleGroups?()
        return true
    }

    public func upsert(_ snippet: Snippet) {
        _ = saveSnippet(snippet)
    }

    @discardableResult
    public func saveSnippet(_ snippet: Snippet) -> Bool {
        let previous = snippets
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            var updated = snippet
            if snippets[index].packageID == updated.packageID {
                updated.sortIndex = snippets[index].sortIndex
            } else {
                updated.sortIndex = nextSnippetSortIndex(in: updated.packageID)
            }
            snippets[index] = updated
        } else {
            var new = snippet
            new.sortIndex = nextSnippetSortIndex(in: snippet.packageID)
            snippets.append(new)
        }
        guard persistCore() else {
            snippets = previous
            return false
        }
        return true
    }

    public func delete(snippetIDs: [Snippet.ID]) {
        _ = removeSnippets(snippetIDs)
    }

    @discardableResult
    public func removeSnippets(_ snippetIDs: [Snippet.ID]) -> Bool {
        let previous = snippets
        let previousHosts = hosts
        let previousGroups = groups
        let doomed = Set(snippetIDs)
        clearStartupSnippetReferences(to: doomed)
        snippets.removeAll { doomed.contains($0.id) }
        guard persistCore() else {
            snippets = previous
            hosts = previousHosts
            groups = previousGroups
            return false
        }
        return true
    }

    public func upsert(_ package: SnippetPackage) {
        _ = saveSnippetPackage(package)
    }

    @discardableResult
    public func saveSnippetPackage(_ package: SnippetPackage) -> Bool {
        let previous = snippetPackages
        if let index = snippetPackages.firstIndex(where: { $0.id == package.id }) {
            let forbidden = Set(
                [package.id] + descendantSnippetPackages(of: package.id).map(\.id)
            )
            guard package.parentID.map(forbidden.contains) != true else { return false }
            var updated = package
            if snippetPackages[index].parentID != updated.parentID {
                updated.sortIndex = nextSnippetPackageSortIndex(under: updated.parentID)
            }
            snippetPackages[index] = updated
        } else {
            guard package.parentID != package.id else { return false }
            var new = package
            new.sortIndex = nextSnippetPackageSortIndex(under: package.parentID)
            snippetPackages.append(new)
        }
        guard persistCore() else {
            snippetPackages = previous
            return false
        }
        expandSnippetPackageAncestors(package.id)
        return true
    }

    public func delete(snippetPackageID: SnippetPackage.ID, keepSnippets: Bool) {
        _ = removeSnippetPackage(snippetPackageID, keepSnippets: keepSnippets)
    }

    @discardableResult
    public func removeSnippetPackage(_ snippetPackageID: SnippetPackage.ID, keepSnippets: Bool) -> Bool {
        let previous = snippets
        let previousPackages = snippetPackages
        let previousHosts = hosts
        let previousGroups = groups
        let doomed = Set(
            [snippetPackageID] + descendantSnippetPackages(of: snippetPackageID).map(\.id)
        )
        if keepSnippets {
            for index in snippets.indices where snippets[index].packageID.map(doomed.contains) == true {
                snippets[index].packageID = nil
                snippets[index].sortIndex = nextSnippetSortIndex(in: nil)
            }
        } else {
            let doomedSnippetIDs = Set(
                snippets.lazy.filter { $0.packageID.map(doomed.contains) == true }.map(\.id)
            )
            clearStartupSnippetReferences(to: doomedSnippetIDs)
            snippets.removeAll { doomedSnippetIDs.contains($0.id) }
        }
        snippetPackages.removeAll { doomed.contains($0.id) }
        guard persistCore() else {
            snippets = previous
            snippetPackages = previousPackages
            hosts = previousHosts
            groups = previousGroups
            return false
        }
        reconcileExpansionState()
        return true
    }

    private func clearStartupSnippetReferences(to snippetIDs: Set<Snippet.ID>) {
        guard !snippetIDs.isEmpty else { return }
        for index in hosts.indices where hosts[index].startupSnippetID.map(snippetIDs.contains) == true {
            hosts[index].startupSnippetID = nil
        }
        for index in groups.indices {
            guard var configuration = groups[index].tailscale else { continue }
            for id in configuration.hostPreferences.keys
            where configuration.hostPreferences[id]?.startupSnippetID.map(snippetIDs.contains) == true {
                configuration.hostPreferences[id]?.startupSnippetID = nil
            }
            groups[index].tailscale = configuration
        }
    }

    public func move(
        snippetIDs: [Snippet.ID], into packageID: SnippetPackage.ID?,
        before next: Snippet.ID? = nil
    ) {
        if let packageID, snippetPackage(packageID) == nil { return }
        guard
            let placement = manualOrderPlacement(
                snippetIDs, before: next,
                destinationItems: snippets(in: packageID),
                validIDs: Set(snippets.map(\.id)), sortIndex: \Snippet.sortIndex
            )
        else { return }
        if placement.moving.allSatisfy({ snippet($0)?.packageID == packageID })
            && snippets(in: packageID).map(\.id) == placement.resulting
        {
            return
        }

        let moving = Set(placement.moving)
        for index in snippets.indices {
            if moving.contains(snippets[index].id) { snippets[index].packageID = packageID }
            if let position = placement.positions[snippets[index].id] {
                snippets[index].sortIndex = position
            }
        }
        expandSnippetPackageAncestors(packageID)
        persistCore()
    }

    @discardableResult
    public func upsert(_ forwarding: PortForwardingRule) -> Bool {
        guard var normalized = PortForwardingEditorPolicy.normalized(forwarding),
            let host = host(forwarding.hostID), host.sshEnabled
        else {
            storageError = String(localized: "The forwarding rule requires an SSH-enabled Host.")
            return false
        }
        normalized.label = SavedName.resolve(
            normalized.label,
            default: normalized.defaultName(hostName: SavedName.resolve(host.name, default: host.defaultName)))
        let previous = portForwardings
        if let index = portForwardings.firstIndex(where: { $0.id == normalized.id }) {
            if portForwardings[index] == normalized { return true }
            willDeletePortForwardings?([normalized.id])
            portForwardings[index] = normalized
        } else {
            portForwardings.append(normalized)
        }
        guard persistCore() else {
            portForwardings = previous
            return false
        }
        return true
    }

    @discardableResult
    public func deletePortForwardings(_ ids: Set<PortForwardingRule.ID>) -> Bool {
        let affected = portForwardings.filter { ids.contains($0.id) }.map(\.id)
        guard !affected.isEmpty else { return true }
        let previous = portForwardings
        willDeletePortForwardings?(affected)
        portForwardings.removeAll { ids.contains($0.id) }
        guard persistCore() else {
            portForwardings = previous
            return false
        }
        return true
    }

    /// Root jump first and destination last. A nil result means the proposed
    /// host closes a cycle, references a missing jump, or exceeds eight hosts.
    public func validatedRoute(for proposed: Host) -> [Host]? {
        Self.validatedRoute(for: proposed, lookup: host)
    }

    /// Shares route policy with batch projections that already have an indexed host lookup.
    public nonisolated static func validatedRoute(for proposed: Host, lookup: (Host.ID) -> Host?) -> [Host]? {
        var route: [Host] = []
        var cursor: Host? = proposed
        var visited: Set<Host.ID> = []
        while let current = cursor {
            guard current.sshEnabled else { return nil }
            if current.isTailscaleManaged && (current.id != proposed.id || current.jumpHostID != nil) { return nil }
            guard visited.insert(current.id).inserted, route.count < 8 else { return nil }
            route.append(current)
            guard let jumpID = current.jumpHostID else { break }
            if jumpID == proposed.id { return nil }
            cursor = lookup(jumpID)
            if cursor == nil { return nil }
        }
        return route.reversed()
    }

    public func route(for host: Host) -> [Host] {
        validatedRoute(for: host) ?? [host]
    }

    public func routeSummary(for host: Host) -> String {
        route(for: host).map { node in
            if let proxy = node.proxy {
                return "\(proxy.kind.displayName) \(proxy.hostname):\(proxy.port) → \(node.displayAddress)"
            }
            return node.displayAddress
        }.joined(separator: " → ")
    }

    /// OpenSSH equivalent when the route needs no in-process Proxy. Passwords,
    /// private keys, and proxy credentials never enter the clipboard.
    public func sshCommand(for host: Host, username: String? = nil) -> String? {
        sshCommand(for: host, additionalArguments: [], username: username)
    }

    public func telnetCommand(for host: Host) -> String {
        var arguments: [String] = []
        if let username = identity(for: host, protocol: .telnet)?.username
            .trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty
        {
            arguments += ["-l", username]
        }
        arguments.append(host.host)
        if host.telnetPort != HostTerminalProtocol.telnet.defaultPort {
            arguments.append(String(host.telnetPort))
        }
        return (["telnet"] + arguments).map(Self.shellQuoted).joined(separator: " ")
    }

    public func sshCommand(for rule: PortForwardingRule, host proposedHost: Host? = nil) -> String? {
        guard let destination = proposedHost ?? host(rule.hostID), destination.id == rule.hostID
        else { return nil }
        var arguments = ["-N"]
        switch rule.kind {
        case .local:
            guard let host = rule.targetHost, let port = rule.targetPort else { return nil }
            arguments += ["-L", "\(rule.bindAddress):\(Self.commandAddress(host, port: port))"]
        case .remote:
            guard let host = rule.targetHost, let port = rule.targetPort else { return nil }
            arguments += ["-R", "\(rule.bindAddress):\(Self.commandAddress(host, port: port))"]
        case .dynamic:
            arguments += ["-D", rule.bindAddress]
        }
        return sshCommand(for: destination, additionalArguments: arguments)
    }

    private func sshCommand(
        for destination: Host, additionalArguments: [String], username: String? = nil
    ) -> String? {
        guard destination.sshEnabled, let route = validatedRoute(for: destination),
            route.allSatisfy({ $0.proxy == nil })
        else { return nil }

        let jumps = route.dropLast().map { node in
            Self.openSSHAddress(
                host: node.host, port: node.port,
                username: identity(for: node)?.username, bracketsIPv6: true
            )
        }
        var arguments = additionalArguments
        if !jumps.isEmpty { arguments += ["-J", jumps.joined(separator: ",")] }
        if destination.port != 22 { arguments += ["-p", String(destination.port)] }
        arguments.append(
            Self.openSSHAddress(
                host: destination.host, port: 22,
                username: username
                    ?? (destination.isTailscaleManaged
                        ? savedTailscaleUsername(for: destination) : identity(for: destination)?.username),
                bracketsIPv6: false
            )
        )
        let suffix = arguments.map(Self.shellQuoted).joined(separator: " ")
        return suffix.isEmpty ? "ssh" : "ssh \(suffix)"
    }

    private static func openSSHAddress(
        host: String, port: Int, username: String?, bracketsIPv6: Bool
    ) -> String {
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = bracketsIPv6 && host.contains(":") ? "[\(host)]" : host
        let address = port == 22 ? resolvedHost : "\(resolvedHost):\(port)"
        guard let trimmedUsername, !trimmedUsername.isEmpty else { return address }
        return "\(trimmedUsername)@\(address)"
    }

    /// POSIX-shell quoting for a single argument. Common SSH punctuation stays
    /// readable; everything else uses single quotes without losing apostrophes.
    private static func shellQuoted(_ value: String) -> String {
        // Keep this an explicit byte loop: the Release build has miscompiled
        // the CharacterSet.contains method reference passed to allSatisfy.
        var requiresQuoting = value.isEmpty
        for byte in value.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:  // 0-9, A-Z, a-z
                continue
            case 0x5F, 0x40, 0x25, 0x2B, 0x3D, 0x3A, 0x2C, 0x2E, 0x2F, 0x2D:  // _@%+=:,./-
                continue
            default:
                requiresQuoting = true
            }
            break
        }
        if !requiresQuoting { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func commandAddress(_ host: String, port: Int) -> String {
        "\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }

    public func setSFTPTransferState(_ state: SFTPTransfer.State, for id: SFTPTransfer.ID) {
        guard let index = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[index].state = state
        sftpTransferStateDidChange?(sftpTransfers[index])
    }

    public func enqueueSFTPTransfer(_ sftpTransfer: SFTPTransfer) {
        sftpTransfers.append(sftpTransfer)
        sftpTransferStateDidChange?(sftpTransfer)
    }

    public func sftpTransfer(_ id: SFTPTransfer.ID) -> SFTPTransfer? {
        sftpTransfers.first { $0.id == id }
    }

    public func updateSFTPTransfer(
        _ id: SFTPTransfer.ID, completedBytes: Int64, totalBytes: Int64,
        bytesPerSecond: Int64
    ) {
        guard let index = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[index].transferredBytes = completedBytes
        sftpTransfers[index].byteCount = totalBytes
        sftpTransfers[index].bytesPerSecond = bytesPerSecond
    }

    public func finishSFTPTransfer(_ id: SFTPTransfer.ID, state: SFTPTransfer.State) {
        guard let index = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[index].state = state
        sftpTransfers[index].bytesPerSecond = 0
        sftpTransfers[index].completedAt = Date()
        if state == .completed {
            sftpTransfers[index].transferredBytes = sftpTransfers[index].byteCount
        }
        sftpTransferStateDidChange?(sftpTransfers[index])
    }

    /// Clears terminal transfer records while leaving queued, running and paused work
    /// untouched. The transfer center is a current-session history, not a log.
    public func clearFinishedSFTPTransfers() {
        let ids = Set(sftpTransfers.filter { $0.state.isFinished }.map(\.id))
        sftpTransfers.removeAll { $0.state.isFinished }
        if !ids.isEmpty { sftpTransfersDidRemove?(ids) }
    }

    /// Removes one terminal record without affecting its downloaded file or live transfers.
    public func removeFinishedSFTPTransfer(_ id: SFTPTransfer.ID) {
        guard let transfer = sftpTransfer(id), transfer.state.isFinished else { return }
        sftpTransfers.removeAll { $0.id == id }
        sftpTransfersDidRemove?([id])
    }

    /// Files one or more hosts into a group, preserving the order supplied.
    ///
    /// `next` is the host that should follow the moved batch; `nil` appends it.
    /// Updating every host before persisting makes a multi-selection one logical
    /// drag instead of a series of partially saved moves.
    public func move(hostIDs: [Host.ID], into group: HostGroup.ID?, before next: Host.ID? = nil) {
        guard hostIDs.allSatisfy({ host($0)?.isTailscaleManaged != true }) else { return }
        if let group, self.group(group) == nil { return }
        guard
            let placement = manualOrderPlacement(
                hostIDs, before: next,
                destinationItems: hosts(in: group),
                validIDs: Set(hosts.map(\.id)),
                sortIndex: \Host.sortIndex
            )
        else { return }
        if placement.moving.allSatisfy({ host($0)?.groupID == group })
            && hosts(in: group).map(\.id) == placement.resulting
        {
            return
        }

        let movingSet = Set(placement.moving)
        for index in hosts.indices {
            if movingSet.contains(hosts[index].id) { hosts[index].groupID = group }
            if let value = placement.positions[hosts[index].id] {
                hosts[index].sortIndex = value
            }
        }
        persistCore()
    }

    @discardableResult
    public func saveKnownHost(_ entry: KnownHostEntry) -> Bool {
        var entry = entry
        entry.hostname = entry.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.fingerprint = entry.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entry.isValid,
            !knownHosts.contains(where: {
                $0.id != entry.id && $0.hostname == entry.hostname && $0.port == entry.port
                    && $0.identity == entry.identity
            })
        else {
            storageError = String(localized: "One or more Known Hosts entries are incomplete or duplicated.")
            return false
        }
        let previous = knownHosts
        if let index = knownHosts.firstIndex(where: { $0.id == entry.id }) {
            if knownHosts[index].identity != entry.identity || knownHosts[index].hostname != entry.hostname
                || knownHosts[index].port != entry.port
            {
                entry.addedAt = Date()
            }
            knownHosts[index] = entry
        } else {
            entry.addedAt = Date()
            knownHosts.append(entry)
        }
        guard persistCore() else {
            knownHosts = previous
            return false
        }
        return true
    }

    @discardableResult
    public func deleteKnownHosts(_ ids: Set<UUID>) -> Bool {
        let previous = knownHosts
        knownHosts.removeAll { ids.contains($0.id) }
        guard persistCore() else {
            knownHosts = previous
            return false
        }
        return true
    }

    /// Saves a complete temporary route in one Vault transaction. Existing Hosts
    /// and Identities are reused or copied, never edited by a one-off command.
    public func saveConnectionRoute(
        _ route: SSHConnectionRoute, authentication: SSHAuthenticationSubmission? = nil,
        authenticationHostID: Host.ID? = nil, suppliedPassword: String? = nil
    ) throws -> SSHConnectionRoute {
        guard route.isValid else { throw SSHConnectionRoute.invalidRouteError }
        for node in route.hosts { try requireHostAccess(node) }
        for id in route.sourceHostIDs.values {
            if let source = host(id) { try requireHostAccess(source) }
        }
        if let managed = route.hosts.first(where: \.isTailscaleManaged) {
            guard route.hosts.count == 1, host(managed.id)?.tailscale == managed.tailscale else {
                throw TailscaleConfigurationError.managedHost
            }
            if let username = authentication?.username ?? route.usernames[managed.id],
                !saveTailscaleUsername(username, hostID: managed.id)
            {
                throw TailscaleConfigurationError.unavailable
            }
            return route
        }
        var batch = SSHImportBatch()
        var saved: [Host] = []
        var usernames: [Host.ID: String] = [:]
        var passwords: [(Identity, String)] = []
        var usedNames = Set(hosts.map(\.name))
        for var node in route.hosts {
            let originalID = node.id
            let source = route.sourceHostIDs[originalID].flatMap(host) ?? host(originalID)
            let username = route.usernames[originalID] ?? identity(for: node)?.username
            if node.id == authenticationHostID, let authentication {
                if let selected = authentication.identityID.flatMap(identity), suppliedPassword == nil {
                    node.identityID = selected.id
                } else {
                    let login = Identity(
                        name: authentication.username, username: authentication.username,
                        credentialRef: suppliedPassword == nil ? "" : "termind.password.\(UUID().uuidString)",
                        keyID: authentication.keyID
                    )
                    batch.identities.append(login)
                    if let suppliedPassword { passwords.append((login, suppliedPassword)) }
                    node.identityID = login.id
                }
            } else if node.identityID == nil, let username, !username.isEmpty {
                let matches = (identities + batch.identities).filter { $0.username == username }
                if matches.count == 1 {
                    node.identityID = matches[0].id
                } else {
                    let login = Identity(name: username, username: username)
                    batch.identities.append(login)
                    node.identityID = login.id
                }
            }
            node.jumpHostID = saved.last?.id
            if let existing = host(originalID), existing != node { node.id = UUID() }
            if host(node.id) == nil {
                let base = source.map { String(localized: "\($0.name) copy") } ?? node.name
                var name = base
                var suffix = 2
                while usedNames.contains(name) {
                    name = "\(base) (\(suffix))"
                    suffix += 1
                }
                node.name = name
                usedNames.insert(name)
                batch.hosts.append(node)
            }
            usernames[node.id] = originalID == authenticationHostID ? authentication?.username : username
            saved.append(node)
        }
        var written: [Identity] = []
        try requireSavingHosts(batch.hosts)
        do {
            for (identity, password) in passwords {
                try setPasswordString(password, for: identity.credentialRef, storage: identity.passwordStorage)
                written.append(identity)
            }
            if !batch.hosts.isEmpty || !batch.identities.isEmpty { try commitSSHImport(batch) }
        } catch {
            let saveError = error
            for identity in written {
                do {
                    try removePassword(identity.credentialRef, storage: identity.passwordStorage)
                } catch {
                    throw TermindSSHError.library(
                        String(
                            localized:
                                "The database save and Keychain rollback both failed: \(error.localizedDescription)")
                    )
                }
            }
            throw saveError
        }
        return SSHConnectionRoute(
            hosts: saved.map { host($0.id) ?? $0 }, usernames: usernames,
            sourceHostIDs: Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0.id) })
        )
    }

    /// New records only. Existing credentials and host configurations are never overwritten.
    public func commitSSHImport(_ batch: SSHImportBatch) throws {
        try requireSavingHosts(batch.hosts)
        let oldHosts = hosts
        let oldIdentities = identities
        let oldKeys = keys
        let oldKnownHosts = knownHosts
        guard Set(batch.hosts.map(\.id)).isDisjoint(with: hosts.map(\.id)),
            Set(batch.keys.map(\.id)).isDisjoint(with: keys.map(\.id)),
            Set(batch.identities.map(\.id)).isDisjoint(with: identities.map(\.id)),
            batch.knownHosts.allSatisfy(\.isValid)
        else { throw CocoaError(.coderInvalidValue) }
        var written: [SSHKeyRef] = []
        do {
            for key in batch.keys {
                guard let secret = batch.credentials[key.id] else {
                    throw CocoaError(.coderValueNotFound)
                }
                try keychain.setKeyCredential(secret, for: key.credentialRef, storage: key.storage)
                written.append(key)
            }
            for var key in batch.keys {
                key.sortIndex = (keys.map(\.sortIndex).max() ?? -1) + 1
                keys.append(key)
            }
            for var identity in batch.identities {
                identity.sortIndex = (identities.map(\.sortIndex).max() ?? -1) + 1
                identities.append(identity)
            }
            for var host in batch.hosts {
                host.createdAt = .now
                host.sortIndex = nextSortIndex(in: nil)
                hosts.append(host)
            }
            guard batch.hosts.allSatisfy({ validatedRoute(for: $0) != nil }) else {
                throw CocoaError(.coderInvalidValue)
            }
            knownHosts.append(contentsOf: batch.knownHosts)
            guard persistCore() else {
                throw TermindSSHError.library(storageError ?? String(localized: "Import failed."))
            }
        } catch {
            hosts = oldHosts
            identities = oldIdentities
            keys = oldKeys
            knownHosts = oldKnownHosts
            var cleanupFailed = false
            for key in written {
                do { try keychain.removeKeyCredential(key.credentialRef, storage: key.storage) } catch {
                    cleanupFailed = true
                }
            }
            if cleanupFailed {
                storageError = String(
                    localized: "Import failed. Some newly stored keys could not be removed from Keychain.")
                throw TermindSSHError.library(storageError!)
            }
            throw error
        }
    }

    private func nextSortIndex(in group: HostGroup.ID?) -> Double {
        (hosts(in: group).last?.sortIndex ?? 0) + 1
    }

    /// The same, for a group among its siblings. Separate from the hosts version
    /// because the two number different collections: a new child of Production is
    /// placed after Production's last *group*, and the hosts filed directly in
    /// Production have their own independent run of indices.
    private func nextSortIndex(under parent: HostGroup.ID?) -> Double {
        let siblings = parent.map { childGroups(of: $0) } ?? rootGroups
        return (siblings.last?.sortIndex ?? 0) + 1
    }

    private func nextSnippetSortIndex(in package: SnippetPackage.ID?) -> Double {
        (snippets(in: package).last?.sortIndex ?? -1) + 1
    }

    private func nextSnippetPackageSortIndex(under parent: SnippetPackage.ID?) -> Double {
        let siblings = parent.map { childSnippetPackages(of: $0) } ?? rootSnippetPackages
        return (siblings.last?.sortIndex ?? -1) + 1
    }

    private func expandSnippetPackageAncestors(_ packageID: SnippetPackage.ID?) {
        var current = packageID
        var visited: Set<SnippetPackage.ID> = []
        while let id = current, let package = snippetPackage(id),
            visited.insert(id).inserted
        {
            current = package.parentID
        }
        expansionState.setSnippetPackagesExpanded(visited)
    }

    private func reconcileExpansionState() {
        expansionState.reconcile(
            hostGroupIDs: Set(groups.map(\.id)),
            snippetPackageIDs: Set(snippetPackages.map(\.id))
        )
    }

    @discardableResult
    private func persistCore(touching touchedKeys: Set<VaultRecordKey> = []) -> Bool {
        do {
            try vault.save(
                VaultSnapshot(
                    hosts: hosts.filter { !$0.isTailscaleManaged }, groups: groups, identities: identities,
                    keys: keys, knownHosts: knownHosts, snippets: snippets,
                    snippetPackages: snippetPackages, portForwardings: portForwardings,
                    workspaceTemplates: workspaceTemplates
                ),
                touching: touchedKeys)
            storageError = nil
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    /// Applies a CloudKit-imported projection without writing it back as a new
    /// local edit. Runtime connection and transfer state intentionally remain.
    public func replacePersistedSnapshot(_ snapshot: VaultSnapshot) {
        let incomingNetworks = Dictionary(
            uniqueKeysWithValues: snapshot.groups.compactMap { group in
                group.tailscale.map { (group.id, $0.network) }
            })
        let removedTailnets = Set(
            groups.filter {
                $0.tailscale != nil && $0.tailscale?.network != incomingNetworks[$0.id]
            }.map(\.id))
        let removedManaged = Set(
            hosts.filter { $0.tailscale.map { removedTailnets.contains($0.groupID) } == true }.map(\.id))

        for id in removedTailnets { tailscalePeers[id] = nil }
        hosts = snapshot.hosts
        groups = snapshot.groups
        rebuildTailscaleHosts()
        identities = normalizedManualOrder(
            snapshot.identities, sortIndex: \Identity.sortIndex, name: \Identity.name
        )
        keys = normalizedManualOrder(
            snapshot.keys, sortIndex: \SSHKeyRef.sortIndex, name: \SSHKeyRef.label
        )
        knownHosts = snapshot.knownHosts
        snippets = normalizedSnippetOrder(snapshot.snippets)
        snippetPackages = snapshot.snippetPackages
        portForwardings = snapshot.portForwardings
        workspaceTemplates = snapshot.workspaceTemplates
        statuses = statuses.filter { id, _ in hosts.contains { $0.id == id } }
        connectionStatuses = connectionStatuses.filter { _, value in
            hosts.contains { $0.id == value.hostID }
        }
        reconcileExpansionState()
        storageError = nil
        vault.didApplyRemoteSnapshot()
        didDeleteTailscaleGroups?(removedTailnets, removedManaged)
        didChangeTailscaleGroups?()
    }

    public func tailscaleGroup(for host: Host) -> HostGroup? {
        var next = (self.host(host.id) ?? host).groupID
        var visited = Set<UUID>()
        while let id = next, visited.insert(id).inserted, let group = group(id) {
            if group.tailscale != nil { return group }
            next = group.parentID
        }
        return nil
    }

    public func networkConfigurationStamp(for host: Host) -> Data {
        guard let group = tailscaleGroup(for: host), let configuration = group.tailscale else { return Data() }
        // Only connection inputs belong here; discovery and other peers' preferences
        // must not restart this host's Metrics worker.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return
            (try? encoder.encode([
                "groupID": group.id.uuidString,
                "controlURL": configuration.network.controlURL,
                "dnsSuffix": configuration.network.dnsSuffix,
                "exitNodeID": configuration.exitNodeID ?? "",
                "username": host.isTailscaleManaged ? tailscaleUsername(for: host) : "",
            ])) ?? Data()
    }

    public func tailscaleNetwork(for host: Host) throws -> (any SSHNetworkDialing)? {
        guard let group = tailscaleGroup(for: host) else {
            if host.isTailscaleManaged { throw TailscaleConfigurationError.unavailable }
            return nil
        }
        guard let tailscaleConnections else { throw TailscaleConfigurationError.unavailable }
        return try tailscaleConnections.connection(for: group.id)
    }

    public func tailscaleUsername(for host: Host) -> String {
        savedTailscaleUsername(for: host) ?? "root"
    }

    public func savedTailscaleUsername(for host: Host) -> String? {
        guard let configuration = tailscaleGroup(for: host)?.tailscale else { return nil }
        let override = configuration.hostPreferences[host.id]?.username ?? ""
        let username = (override.isEmpty ? configuration.username : override)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return username.isEmpty ? nil : username
    }

    public func replaceTailscalePeers(_ peers: [TailscalePeer], groupID: UUID) {
        tailscalePeers[groupID] = peers
        rebuildTailscaleHosts()
    }

    private func rebuildTailscaleHosts() {
        var projected = hosts.filter { !$0.isTailscaleManaged }
        var ids = Set(projected.map(\.id))
        for group in groups {
            guard let configuration = group.tailscale else { continue }
            for peer in tailscalePeers[group.id] ?? [] where !peer.stableID.isEmpty && peer.supportsSSH {
                let id = configuration.hostID(groupID: group.id, stableNodeID: peer.stableID)
                guard ids.insert(id).inserted else { continue }
                let preferences = configuration.hostPreferences[id] ?? TailscaleHostPreferences()
                var host = Host(id: id, name: peer.name, host: peer.dnsName, groupID: group.id)
                host.tailscale = TailscaleHostReference(groupID: group.id, stableNodeID: peer.stableID)
                host.detectedDistribution = preferences.detectedDistribution
                host.tags = preferences.tags
                host.colorTag = preferences.colorTag
                host.iconOverrideID = preferences.iconOverrideID
                host.sshCharset = preferences.charset
                host.sftpChannelInitialPath = preferences.sftpInitialPath
                host.wakeOnLAN = preferences.wakeOnLAN
                host.terminalTransports = preferences.terminalTransports
                host.sessionPersistence = preferences.sessionPersistence
                host.shellIntegrationMode = preferences.shellIntegrationMode
                host.startupSnippetID = preferences.startupSnippetID
                host.environmentVariables = preferences.environmentVariables
                projected.append(host)
            }
        }
        hosts = projected
    }

    public func saveTailscaleHost(_ host: Host, username: String? = nil) -> Bool {
        guard host.wakeOnLAN.isValid else {
            storageError = WakeOnLANError.invalidAddress.localizedDescription
            return false
        }
        guard let existing = self.host(host.id), existing.isTailscaleManaged,
            host.tailscale == existing.tailscale, host.groupID == existing.groupID,
            host.name == existing.name, host.host == existing.host, host.port == 22,
            host.identityID == nil, host.jumpHostID == nil, host.proxy == nil,
            !host.telnetEnabled, !host.agentForwardingEnabled,
            let index = groups.firstIndex(where: { $0.id == host.groupID }), groups[index].tailscale != nil
        else {
            storageError = TailscaleConfigurationError.managedHost.localizedDescription
            return false
        }
        let previous = groups
        var preferences = groups[index].tailscale!.hostPreferences[host.id] ?? TailscaleHostPreferences()
        if let username { preferences.username = username.trimmingCharacters(in: .whitespacesAndNewlines) }
        preferences.tags = host.tags
        preferences.colorTag = host.colorTag
        preferences.iconOverrideID = host.iconOverrideID
        preferences.charset = host.sshCharset
        preferences.sftpInitialPath = host.sftpChannelInitialPath
        preferences.wakeOnLAN = host.wakeOnLAN
        preferences.terminalTransports = host.terminalTransports
        preferences.sessionPersistence = host.sessionPersistence
        preferences.shellIntegrationMode = host.shellIntegrationMode
        preferences.startupSnippetID = host.startupSnippetID
        preferences.environmentVariables = host.environmentVariables
        groups[index].tailscale!.hostPreferences[host.id] = preferences
        guard persistCore() else {
            groups = previous
            return false
        }
        rebuildTailscaleHosts()
        return true
    }

    public func saveTailscaleUsername(_ username: String, hostID: UUID) -> Bool {
        guard let host = host(hostID), let index = groups.firstIndex(where: { $0.id == host.groupID }),
            groups[index].tailscale != nil
        else { return false }
        let previous = groups
        var preferences = groups[index].tailscale!.hostPreferences[hostID] ?? TailscaleHostPreferences()
        preferences.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        groups[index].tailscale!.hostPreferences[hostID] = preferences
        guard persistCore() else {
            groups = previous
            return false
        }
        return true
    }
}

// MARK: - Manual ordering

/// A deterministic tie-break keeps hand-built preview data usable before its
/// first move. Persisted data normally has unique
/// fractional indices, so the name is not otherwise part of the ordering.
private func manuallyOrdered(
    _ lhsIndex: Double, _ lhsName: String,
    _ rhsIndex: Double, _ rhsName: String
) -> Bool {
    if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
    return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
}

/// Normalize duplicate preview and unit-test defaults once so their first
/// fractional move has real alphabetical neighbours.
private func normalizedManualOrder<Item>(
    _ values: [Item],
    sortIndex: WritableKeyPath<Item, Double>,
    name: KeyPath<Item, String>
) -> [Item] {
    let indices = values.map { $0[keyPath: sortIndex] }
    guard indices.contains(where: { !$0.isFinite }) || Set(indices).count != indices.count else {
        return values
    }

    var ordered = values.sorted {
        manuallyOrdered(
            $0[keyPath: sortIndex], $0[keyPath: name],
            $1[keyPath: sortIndex], $1[keyPath: name]
        )
    }
    for index in ordered.indices { ordered[index][keyPath: sortIndex] = Double(index) }
    return ordered
}

/// Snippet indices are local to a Package. Equal indices in two different
/// Packages are expected, so normalization must never compare them globally.
private func normalizedSnippetOrder(_ values: [Snippet]) -> [Snippet] {
    var result = values
    for packageID in Set(values.map(\.packageID)) {
        let members = result.indices.filter { result[$0].packageID == packageID }
        let sortIndices = members.map { result[$0].sortIndex }
        guard
            sortIndices.contains(where: { !$0.isFinite })
                || Set(sortIndices).count != sortIndices.count
        else { continue }

        let ordered = members.sorted {
            manuallyOrdered(
                result[$0].sortIndex, result[$0].title,
                result[$1].sortIndex, result[$1].title
            )
        }
        for (position, index) in ordered.enumerated() {
            result[index].sortIndex = Double(position)
        }
    }
    return result
}

private struct ManualOrderPlacement<ID: Hashable> {
    let moving: [ID]
    let resulting: [ID]
    let positions: [ID: Double]
}

/// Generic remove-then-insert calculation shared by Hosts, Keys and Identities.
/// The destination may omit moving IDs (Hosts crossing groups), so validity is
/// supplied separately from the concrete destination collection.
private func manualOrderPlacement<Item: Identifiable>(
    _ requestedIDs: [Item.ID],
    before next: Item.ID?,
    destinationItems: [Item],
    validIDs: Set<Item.ID>,
    sortIndex: KeyPath<Item, Double>
) -> ManualOrderPlacement<Item.ID>? where Item.ID: Hashable {
    var seen: Set<Item.ID> = []
    let moving = requestedIDs.filter {
        validIDs.contains($0) && seen.insert($0).inserted
    }
    guard !moving.isEmpty else { return nil }

    let movingSet = Set(moving)
    let remaining = destinationItems.filter { !movingSet.contains($0.id) }
    let insertionIndex: Int
    if let next {
        guard let index = remaining.firstIndex(where: { $0.id == next }) else { return nil }
        insertionIndex = index
    } else {
        insertionIndex = remaining.endIndex
    }

    let resulting =
        Array(remaining[..<insertionIndex]).map(\.id) + moving
        + Array(remaining[insertionIndex...]).map(\.id)
    let lower = insertionIndex > 0 ? remaining[insertionIndex - 1][keyPath: sortIndex] : nil
    let upper = insertionIndex < remaining.endIndex ? remaining[insertionIndex][keyPath: sortIndex] : nil
    var positions: [Item.ID: Double] = [:]

    switch (lower, upper) {
    case (let lower?, let upper?):
        let step = (upper - lower) / Double(moving.count + 1)
        if step.isFinite && step > 0 {
            for (offset, id) in moving.enumerated() {
                positions[id] = lower + step * Double(offset + 1)
            }
        }
    case (let lower?, nil):
        for (offset, id) in moving.enumerated() {
            positions[id] = lower + Double(offset + 1)
        }
    case (nil, let upper?):
        for (offset, id) in moving.enumerated() {
            positions[id] = upper - Double(moving.count - offset)
        }
    case (nil, nil):
        for (offset, id) in moving.enumerated() { positions[id] = Double(offset) }
    }

    if positions.count != moving.count {
        positions = Dictionary(
            uniqueKeysWithValues: resulting.enumerated().map { ($0.element, Double($0.offset)) }
        )
    }
    return ManualOrderPlacement(moving: moving, resulting: resulting, positions: positions)
}

/// Shared fixed-section wrapper for every manually ordered Keychain collection.
private func reorderManually<Item: Identifiable>(
    _ requestedIDs: [Item.ID],
    before next: Item.ID?,
    items: inout [Item],
    sortIndex: WritableKeyPath<Item, Double>
) -> Bool where Item.ID: Hashable {
    let current = items.sorted { $0[keyPath: sortIndex] < $1[keyPath: sortIndex] }
    guard
        let placement = manualOrderPlacement(
            requestedIDs, before: next, destinationItems: current,
            validIDs: Set(current.map(\.id)), sortIndex: sortIndex
        ), placement.resulting != current.map(\.id)
    else { return false }

    for index in items.indices {
        if let value = placement.positions[items[index].id] {
            items[index][keyPath: sortIndex] = value
        }
    }
    items.sort { $0[keyPath: sortIndex] < $1[keyPath: sortIndex] }
    return true
}
