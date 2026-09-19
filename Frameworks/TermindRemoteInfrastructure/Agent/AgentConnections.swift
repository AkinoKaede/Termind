import AgentKit
import Foundation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

nonisolated public struct AgentHostTarget: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var displayName: String
    public var address: String
    public var tags: [String]
    public var connectionState: String
    public var isTemporary: Bool
    public var groupID: HostGroup.ID?
    public var groupPath: String?

    public init(
        id: UUID, displayName: String, address: String, tags: [String], connectionState: String, isTemporary: Bool,
        groupID: HostGroup.ID? = nil, groupPath: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.address = address
        self.tags = tags
        self.connectionState = connectionState
        self.isTemporary = isTemporary
        self.groupID = groupID
        self.groupPath = groupPath
    }
}

nonisolated public struct AgentHostGroupTarget: Identifiable, Hashable, Sendable {
    public var id: HostGroup.ID
    public var name: String
    public var path: String
    public var children: [AgentHostGroupTarget]

    public init(id: HostGroup.ID, name: String, path: String, children: [AgentHostGroupTarget]) {
        self.id = id
        self.name = name
        self.path = path
        self.children = children
    }
}

nonisolated public struct AgentHostListing: Hashable, Sendable {
    public var groups: [AgentHostGroupTarget]
    public var hosts: [AgentHostTarget]

    public init(groups: [AgentHostGroupTarget], hosts: [AgentHostTarget]) {
        self.groups = groups
        self.hosts = hosts
    }
}

/// Main-actor bridge over the Vault. The Agent receives only public host
/// metadata; Keychain material is resolved directly into SSH configuration and
/// never serialized into a tool result.
@MainActor
public final class AgentHostResolver: Sendable {
    private let store: HostLibraryModel
    private var temporaryTargets: @MainActor @Sendable () -> [AgentHostTarget]
    private var temporaryConfiguration: @MainActor @Sendable (UUID) throws -> SSHConnectionConfiguration?

    public init(
        store: HostLibraryModel,
        temporaryTargets: @escaping @MainActor @Sendable () -> [AgentHostTarget] = { [] },
        temporaryConfiguration: @escaping @MainActor @Sendable (UUID) throws -> SSHConnectionConfiguration? = { _ in nil
        }
    ) {
        self.store = store
        self.temporaryTargets = temporaryTargets
        self.temporaryConfiguration = temporaryConfiguration
    }

    public func configureTemporaryTargets(
        targets: @escaping @MainActor @Sendable () -> [AgentHostTarget],
        configuration: @escaping @MainActor @Sendable (UUID) throws -> SSHConnectionConfiguration?
    ) {
        temporaryTargets = targets
        temporaryConfiguration = configuration
    }

    public func listing() -> AgentHostListing {
        let paths = groupPaths()
        let saved = store.hosts.map { host in
            AgentHostTarget(
                id: host.id, displayName: host.name, address: store.loginAddress(for: host),
                tags: host.tags, connectionState: Self.stateName(store.status(of: host.id)),
                isTemporary: false, groupID: host.groupID,
                groupPath: host.groupID.flatMap { paths[$0] }
            )
        }
        return AgentHostListing(
            groups: groupTree(paths: paths),
            hosts: saved
                + temporaryTargets().map { target in
                    var target = target
                    target.groupID = nil
                    target.groupPath = nil
                    return target
                }
        )
    }

    /// Produces every valid path without trusting persisted parent links to be
    /// acyclic. A broken parent simply ends the path; a cycle never recurses.
    private func groupPaths() -> [HostGroup.ID: String] {
        var result: [HostGroup.ID: String] = [:]
        for group in store.groups {
            var names: [String] = []
            var current: HostGroup? = group
            var visited: Set<HostGroup.ID> = []
            while let node = current, visited.insert(node.id).inserted {
                names.append(node.name)
                current = node.parentID.flatMap(store.group)
            }
            result[group.id] = names.reversed().joined(separator: " / ")
        }
        return result
    }

    /// Roots include ordinary top-level groups and groups whose parent is
    /// missing. Any cyclic component that has no root is appended afterwards,
    /// exactly once, so corrupt metadata cannot make a group disappear.
    private func groupTree(paths: [HostGroup.ID: String]) -> [AgentHostGroupTarget] {
        let all = Dictionary(uniqueKeysWithValues: store.groups.map { ($0.id, $0) })
        func ordered(_ groups: [HostGroup]) -> [HostGroup] {
            groups.sorted {
                if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        var emitted: Set<HostGroup.ID> = []
        func build(_ group: HostGroup, ancestors: Set<HostGroup.ID>) -> AgentHostGroupTarget {
            emitted.insert(group.id)
            let nextAncestors = ancestors.union([group.id])
            let children = ordered(store.groups.filter { $0.parentID == group.id })
                .filter { !nextAncestors.contains($0.id) }
                .map { build($0, ancestors: nextAncestors) }
            return AgentHostGroupTarget(
                id: group.id, name: group.name, path: paths[group.id] ?? group.name,
                children: children
            )
        }
        let roots = ordered(
            store.groups.filter { group in
                guard let parentID = group.parentID else { return true }
                return all[parentID] == nil
            })
        var result = roots.map { build($0, ancestors: []) }
        for group in ordered(store.groups) where !emitted.contains(group.id) {
            result.append(build(group, ancestors: []))
        }
        return result
    }

    public func configuration(for id: UUID) throws -> SSHConnectionConfiguration {
        if let host = store.host(id) { return try store.sshConnectionConfiguration(for: host) }
        if let configuration = try temporaryConfiguration(id) { return configuration }
        throw AgentToolError.invalidHost
    }

    public func canResolve(_ id: UUID) -> Bool {
        store.host(id) != nil || temporaryTargets().contains { $0.id == id }
    }

    fileprivate struct InteractiveResolution: Sendable {
        var configuration: SSHConnectionConfiguration
        var submissions: [Host.ID: SSHAuthenticationSubmission]
        var temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    }

    /// Resolves every local authentication checkpoint in route order. The
    /// interaction handler receives public metadata and returns secrets
    /// directly to this main-actor bridge; none of it becomes tool content.
    fileprivate func interactiveConfiguration(
        for id: UUID,
        invocationID: AgentToolInvocation.ID,
        interaction: AgentSSHInteraction,
        submissions initial: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys initialTemporaryHostKeys: [Host.ID: SSHHostKeyIdentity],
        forcedHostID initialForcedHostID: Host.ID? = nil,
        failure initialFailure: String? = nil
    ) async throws -> InteractiveResolution {
        guard let destination = store.host(id) else {
            // Pane-backed targets already carry a complete configuration and
            // cannot be saved back to the Vault from an Agent card.
            if let configuration = try temporaryConfiguration(id) {
                return InteractiveResolution(
                    configuration: configuration, submissions: initial,
                    temporaryHostKeys: initialTemporaryHostKeys
                )
            }
            throw AgentToolError.invalidHost
        }

        var submissions = initial
        let temporaryHostKeys = initialTemporaryHostKeys
        var forcedHostID = initialForcedHostID
        var failure = initialFailure
        // Match Terminal and SFTP: resolve local credential requirements first,
        // then begin the network handshake and host-key verification. In
        // particular, a protected key must raise Passphrase even when the peer
        // later fails before returning its SSH banner.
        for node in store.route(for: destination) {
            while let requirement = authenticationRequirement(
                for: node, submissions: submissions, forcedHostID: forcedHostID
            ) {
                let existing = submissions[node.id]
                let identity =
                    existing?.identityID.flatMap(store.identity)
                    ?? store.identity(for: node)
                let request = AgentSSHAuthenticationRequest(
                    invocationID: invocationID, hostID: node.id,
                    displayName: node.name, address: node.displayAddress,
                    mode: requirement.mode,
                    selectedIdentityID: existing?.identityID ?? identity?.id,
                    username: existing?.username ?? identity?.username ?? "",
                    selectedKeyID: existing?.keyID ?? identity?.keyID,
                    failureMessage: failure
                )
                switch await interaction.authenticate(request) {
                case .cancelled, .keyboardInteractive:
                    throw AgentToolError.cancelled
                case .submit(let answer):
                    if case .passphrase = requirement.mode,
                        var retained = submissions[node.id]
                    {
                        // A protected key may have been chosen beside a password
                        // in the preceding Identity step. The passphrase card only
                        // returns the newly-entered secret, so merge it into that
                        // staged submission instead of replacing (and silently
                        // dropping) the password and other choices.
                        guard let passphrase = answer.passphrase, !passphrase.isEmpty else {
                            throw TermindSSHError.keyPassphraseRequired
                        }
                        retained.passphrase = passphrase
                        submissions[node.id] = retained
                    } else {
                        submissions[node.id] = try submission(from: answer, for: node)
                    }
                }
                forcedHostID = nil
                failure = nil
            }

        }

        return InteractiveResolution(
            configuration: try store.sshConnectionConfiguration(
                for: destination, submissions: submissions,
                temporaryHostKeys: temporaryHostKeys,
                trustPolicy: .allowChallenge
            ),
            submissions: submissions, temporaryHostKeys: temporaryHostKeys
        )
    }

    fileprivate func confirmHostKey(
        _ challenge: SSHHostKeyChallenge,
        invocationID: AgentToolInvocation.ID,
        interaction: AgentSSHInteraction
    ) async -> AgentSSHHostKeyResponse {
        let saved = store.host(challenge.hostID)
        let temporary = temporaryTargets().first { $0.id == challenge.hostID }
        let displayName = saved?.name ?? temporary?.displayName ?? challenge.observation.hostname
        let address =
            saved?.displayAddress ?? temporary?.address
            ?? (challenge.observation.port == 22
                ? challenge.observation.hostname
                : "\(challenge.observation.hostname):\(challenge.observation.port)")
        if !challenge.expectedHostKeys.isEmpty {
            store.markKnownHostMismatched(
                hostname: challenge.observation.hostname,
                port: challenge.observation.port
            )
        }
        let response = await interaction.confirmHostKey(
            AgentSSHHostKeyRequest(
                invocationID: invocationID, hostID: challenge.hostID,
                displayName: displayName, address: address,
                prompt: SSHHostKeyPrompt(
                    observation: challenge.observation,
                    kind: challenge.expectedHostKeys.isEmpty
                        ? .firstUse
                        : .additionalKey(trustedKeyCount: challenge.expectedHostKeys.count)
                ),
                allowsPersistentTrust: saved != nil
            )
        )
        if response == .trustAndContinue, saved != nil {
            store.trust(
                KnownHostEntry(
                    hostname: challenge.observation.hostname,
                    port: challenge.observation.port,
                    algorithm: challenge.observation.algorithm,
                    fingerprint: challenge.observation.fingerprint,
                    addedAt: .now
                )
            )
        }
        return response
    }

    private struct AuthenticationRequirement {
        var mode: AgentSSHAuthenticationRequest.Mode
    }

    private func authenticationRequirement(
        for host: Host,
        submissions: [Host.ID: SSHAuthenticationSubmission],
        forcedHostID: Host.ID?
    ) -> AuthenticationRequirement? {
        guard forcedHostID == nil || forcedHostID == host.id else { return nil }
        if let submission = submissions[host.id] {
            if let keyID = submission.keyID,
                store.key(keyID)?.requiresPassphraseEntry == true,
                submission.passphrase?.isEmpty != false
            {
                return AuthenticationRequirement(mode: .passphrase(keyID: keyID))
            }
            if submission.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return AuthenticationRequirement(mode: .identity)
            }
            if forcedHostID == host.id {
                return AuthenticationRequirement(mode: .identity)
            }
            return nil
        }
        guard let identity = store.identity(for: host) else {
            return AuthenticationRequirement(mode: .identity)
        }
        let resolution = store.sshCredentials(for: identity)
        if let keyID = resolution.requiredPassphraseKeyID {
            return AuthenticationRequirement(mode: .passphrase(keyID: keyID))
        }
        if identity.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (identity.hasSecret && resolution.credentials.isEmpty)
        {
            return AuthenticationRequirement(mode: .identity)
        }
        if forcedHostID == host.id {
            return AuthenticationRequirement(mode: .identity)
        }
        return nil
    }

    private func submission(
        from answer: AgentSSHAuthenticationAnswer, for host: Host
    ) throws -> SSHAuthenticationSubmission {
        if let identityID = answer.identityID {
            guard let identity = store.identity(identityID) else {
                throw TermindSSHError.missingCredential
            }
            let password = try store.connectionPasswordCredential(for: identity)
            if answer.save {
                var updated = host
                updated.identityID = identity.id
                store.upsert(updated)
            }
            return SSHAuthenticationSubmission(
                username: identity.username, password: password,
                passphrase: answer.passphrase, keyID: identity.keyID,
                identityID: identity.id
            )
        }

        let username = answer.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { throw TermindSSHError.missingUsername }
        var identityID: Identity.ID?
        if answer.save {
            let name = answer.identityName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = Identity(
                name: name?.isEmpty == false ? name! : username,
                username: username, keyID: answer.keyID
            )
            try store.upsert(
                identity,
                passwordUpdate: answer.password.map(IdentityPasswordUpdate.replace) ?? .remove
            )
            var updated = host
            updated.identityID = identity.id
            store.upsert(updated)
            identityID = identity.id
        }
        return SSHAuthenticationSubmission(
            username: username, password: answer.password,
            passphrase: answer.passphrase, keyID: answer.keyID,
            identityID: identityID
        )
    }

    /// A stable description of *which machine, reached how, and as whom* — the
    /// only question a pooled connection has to keep answering the same way.
    ///
    /// Built from records the store already holds in memory, with deliberately
    /// no Keychain read: this runs before every reuse, and resolving credentials
    /// here would put private-key material on the hot path of every command to
    /// no purpose. A rotated credential on an unchanged identity is therefore
    /// not a mismatch — the live session is still the same box and the same
    /// login, and the new credential applies to the next connect.
    public func routeFingerprint(for id: UUID) throws -> String {
        guard let host = store.host(id) else {
            // A pane-backed target has no Vault record to describe, and its
            // configuration is rebuilt from the live pane on every connect. Tie
            // the fingerprint to that pane still existing, so a closed workspace
            // invalidates the Agent's connection to it.
            guard temporaryTargets().contains(where: { $0.id == id }) else {
                throw AgentToolError.invalidHost
            }
            return "temporary:\(id.uuidString)"
        }
        return store.route(for: host).map { node in
            let identity = store.identity(for: node)
            let proxy = node.proxy.map {
                "\($0.kind.rawValue)://\($0.username)@\($0.hostname):\($0.port)"
            }
            let keys = store.knownHosts(for: node).map(\.fingerprint).sorted()
            return [
                node.id.uuidString, node.host, String(node.port),
                identity?.id.uuidString ?? "", identity?.username ?? "",
                proxy ?? "", keys.joined(separator: ","),
            ].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
    }

    private static func stateName(_ status: ConnectionStatus) -> String {
        switch status {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .reconnecting: "reconnecting"
        case .failed: "failed"
        }
    }
}

/// Keeps temporary credentials alive for one overlapping wave of Agent SSH
/// connection attempts. Exec and SFTP use separate transports, but may need the
/// same user answer at the same time; this actor resolves that answer once.
public actor AgentSSHConfigurationSession {
    public struct Attempt: Sendable {
        public var request: SSHConnectionRequest
        public var generation: UInt64

        public var configuration: SSHConnectionConfiguration { request.configuration }

        public init(request: SSHConnectionRequest, generation: UInt64) {
            self.request = request
            self.generation = generation
        }

        public init(configuration: SSHConnectionConfiguration, generation: UInt64) {
            self.init(
                request: SSHConnectionRequest(configuration: configuration),
                generation: generation
            )
        }
    }

    private struct Pending {
        var generation: UInt64
        var task: Task<AgentHostResolver.InteractiveResolution, any Error>
    }

    private let resolver: AgentHostResolver
    private let hostID: Host.ID
    private let invocationID: AgentToolInvocation.ID
    private let interaction: AgentSSHInteraction
    private var submissions: [Host.ID: SSHAuthenticationSubmission] = [:]
    private var temporaryHostKeys: [Host.ID: SSHHostKeyIdentity] = [:]
    private var cached: SSHConnectionConfiguration?
    private var generation: UInt64 = 0
    private var pending: Pending?
    private var forcedHostID: Host.ID?
    private var failure: String?
    private struct PendingHostKey {
        var fingerprint: String
        var task: Task<AgentSSHHostKeyResponse, Never>
        var waiters: [UUID: CheckedContinuation<AgentSSHHostKeyResponse?, Never>]
    }
    private var pendingHostKeys: [Host.ID: PendingHostKey] = [:]

    public init(
        resolver: AgentHostResolver, hostID: Host.ID,
        invocationID: AgentToolInvocation.ID,
        interaction: AgentSSHInteraction
    ) {
        self.resolver = resolver
        self.hostID = hostID
        self.invocationID = invocationID
        self.interaction = interaction
    }

    public func configurationAttempt() async throws -> Attempt {
        if let cached { return makeAttempt(configuration: cached, generation: generation) }

        let active: Pending
        if let pending, pending.generation == generation {
            active = pending
        } else {
            let currentGeneration = generation
            let resolver = resolver
            let hostID = hostID
            let invocationID = invocationID
            let interaction = interaction
            let submissions = submissions
            let temporaryHostKeys = temporaryHostKeys
            let forcedHostID = forcedHostID
            let failure = failure
            let task = Task {
                try await resolver.interactiveConfiguration(
                    for: hostID, invocationID: invocationID, interaction: interaction,
                    submissions: submissions, temporaryHostKeys: temporaryHostKeys,
                    forcedHostID: forcedHostID, failure: failure
                )
            }
            active = Pending(generation: currentGeneration, task: task)
            pending = active
        }

        do {
            let resolution = try await active.task.value
            if generation == active.generation {
                submissions = resolution.submissions
                temporaryHostKeys = resolution.temporaryHostKeys
                cached = resolution.configuration
                forcedHostID = nil
                failure = nil
                if pending?.generation == active.generation { pending = nil }
            }
            return makeAttempt(
                configuration: resolution.configuration,
                generation: active.generation
            )
        } catch {
            if pending?.generation == active.generation { pending = nil }
            throw error
        }
    }

    /// Convenience for focused resolver tests that do not need to simulate a
    /// rejected transport attempt.
    public func configuration() async throws -> SSHConnectionConfiguration {
        try await configurationAttempt().configuration
    }

    public var currentGeneration: UInt64 { generation }

    public func canResolveTarget() async -> Bool {
        await resolver.canResolve(hostID)
    }

    public func retry(after error: TermindSSHError, generation failedGeneration: UInt64) {
        // Exec and SFTP may reject the same configuration concurrently. Only
        // the first failure advances the attempt; a late failure from the old
        // generation must not erase credentials the user has just re-entered.
        guard failedGeneration == generation else { return }
        let target = error.routeHostID ?? hostID
        if var retained = submissions[target] {
            retained.password = nil
            retained.passphrase = nil
            submissions[target] = retained
        }
        generation &+= 1
        cached = nil
        pending?.task.cancel()
        pending = nil
        forcedHostID = target
        failure = error.localizedDescription
    }

    private func makeAttempt(
        configuration: SSHConnectionConfiguration, generation: UInt64
    ) -> Attempt {
        Attempt(
            request: SSHConnectionRequest(
                configuration: configuration,
                authorizeHostKey: { [weak self] challenge in
                    guard let self else { throw CancellationError() }
                    return await self.authorizeHostKey(
                        challenge, generation: generation
                    )
                },
                keyboardInteractive: { [weak self] challenge in
                    guard let self, await self.currentGeneration == generation else { throw CancellationError() }
                    let answers = try await self.interaction.respondToChallenge(
                        challenge, invocationID: self.invocationID)
                    guard await self.currentGeneration == generation else { throw CancellationError() }
                    return answers
                }
            ),
            generation: generation
        )
    }

    private func authorizeHostKey(
        _ challenge: SSHHostKeyChallenge, generation attemptedGeneration: UInt64
    ) async -> SSHHostKeyDecision {
        guard attemptedGeneration == generation else { return .reject }
        if temporaryHostKeys[challenge.hostID] == challenge.observation.identity {
            return .accept
        }
        let pending: PendingHostKey
        if let existing = pendingHostKeys[challenge.hostID],
            existing.fingerprint == challenge.observation.fingerprint
        {
            pending = existing
        } else {
            let resolver = resolver
            let invocationID = invocationID
            let interaction = interaction
            let task = Task {
                await resolver.confirmHostKey(
                    challenge, invocationID: invocationID,
                    interaction: interaction
                )
            }
            pending = PendingHostKey(
                fingerprint: challenge.observation.fingerprint,
                task: task, waiters: [:]
            )
            pendingHostKeys[challenge.hostID] = pending
            Task { [weak self] in
                let response = await task.value
                await self?.finishHostKeyPrompt(
                    hostID: challenge.hostID,
                    fingerprint: challenge.observation.fingerprint,
                    response: response
                )
            }
        }
        let waiterID = UUID()
        let response: AgentSSHHostKeyResponse? = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<AgentSSHHostKeyResponse?, Never>) in
                guard var current = pendingHostKeys[challenge.hostID],
                    current.fingerprint == pending.fingerprint
                else {
                    continuation.resume(returning: nil)
                    return
                }
                current.waiters[waiterID] = continuation
                pendingHostKeys[challenge.hostID] = current
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelHostKeyWaiter(
                    hostID: challenge.hostID,
                    fingerprint: challenge.observation.fingerprint,
                    waiterID: waiterID
                )
            }
        }
        guard attemptedGeneration == generation else { return .reject }
        switch response {
        case nil:
            return .reject
        case .deny:
            return .reject
        case .continueOnce, .trustAndContinue:
            temporaryHostKeys[challenge.hostID] = challenge.observation.identity
            return .accept
        }
    }

    private func finishHostKeyPrompt(
        hostID: Host.ID, fingerprint: String,
        response: AgentSSHHostKeyResponse
    ) {
        guard let pending = pendingHostKeys[hostID],
            pending.fingerprint == fingerprint
        else { return }
        pendingHostKeys[hostID] = nil
        for continuation in pending.waiters.values {
            continuation.resume(returning: response)
        }
    }

    private func cancelHostKeyWaiter(
        hostID: Host.ID, fingerprint: String, waiterID: UUID
    ) {
        guard var pending = pendingHostKeys[hostID],
            pending.fingerprint == fingerprint,
            let continuation = pending.waiters.removeValue(forKey: waiterID)
        else { return }
        continuation.resume(returning: nil)
        if pending.waiters.isEmpty {
            pending.task.cancel()
            pendingHostKeys[hostID] = nil
        } else {
            pendingHostKeys[hostID] = pending
        }
    }
}

nonisolated public struct AgentSSHExecConnection: Sendable {
    public var authentication: AgentSSHConfigurationSession
    public var client: any SSHExecSessionProtocol

    public init(authentication: AgentSSHConfigurationSession, client: any SSHExecSessionProtocol) {
        self.authentication = authentication
        self.client = client
    }
}

/// Shares one temporary authentication session among connection attempts that
/// overlap for the same destination. The entry disappears with the last lease,
/// so Custom passwords and passphrases never become a time-based credential
/// cache between otherwise unrelated tool calls.
public actor AgentSSHAuthenticationRegistry {
    private struct Entry {
        var token: UUID
        var session: AgentSSHConfigurationSession
        var leases: Int
    }

    private let resolver: AgentHostResolver
    private var entries: [Host.ID: Entry] = [:]

    public init(resolver: AgentHostResolver) { self.resolver = resolver }

    public func exec(
        hostID: Host.ID, invocationID: AgentToolInvocation.ID,
        interaction: AgentSSHInteraction, pool: AgentConnectionPool
    ) async throws -> any SSHExecSessionProtocol {
        try await withSession(
            hostID: hostID, invocationID: invocationID, interaction: interaction
        ) { authentication in
            try await self.openExec(
                hostID: hostID, authentication: authentication, pool: pool
            )
        }
    }

    public func execConnection(
        hostID: Host.ID, invocationID: AgentToolInvocation.ID,
        interaction: AgentSSHInteraction, pool: AgentConnectionPool
    ) async throws -> AgentSSHExecConnection {
        try await withSession(
            hostID: hostID, invocationID: invocationID, interaction: interaction
        ) { authentication in
            let client = try await self.openExec(
                hostID: hostID, authentication: authentication, pool: pool
            )
            return AgentSSHExecConnection(
                authentication: authentication, client: client
            )
        }
    }

    public func openExec(
        hostID: Host.ID, authentication: AgentSSHConfigurationSession,
        pool: AgentConnectionPool
    ) async throws -> any SSHExecSessionProtocol {
        try await openAuthenticated(
            hostID: hostID, authentication: authentication, pool: pool, kind: .exec
        ) { attempt in
            if let attempt {
                return try await pool.exec(hostID: hostID) { _ in attempt.request }
            }
            return try await pool.exec(hostID: hostID)
        }
    }

    public func sftp(
        hostID: Host.ID, invocationID: AgentToolInvocation.ID,
        interaction: AgentSSHInteraction, pool: AgentConnectionPool
    ) async throws -> any SFTPClientProtocol {
        try await withSession(
            hostID: hostID, invocationID: invocationID, interaction: interaction
        ) { authentication in
            try await self.openAuthenticated(
                hostID: hostID, authentication: authentication, pool: pool, kind: .sftp
            ) { attempt in
                if let attempt {
                    return try await pool.sftp(hostID: hostID) { _ in attempt.request }
                }
                return try await pool.sftp(hostID: hostID)
            }
        }
    }

    /// Runs one operation with an exclusive Agent SFTP lease. Authentication
    /// may retry while acquiring the lease; the operation itself is never
    /// replayed.
    public func withSFTP<Value: Sendable>(
        hostID: Host.ID, invocationID: AgentToolInvocation.ID,
        interaction: AgentSSHInteraction, pool: AgentConnectionPool,
        cancellation: TransferCancellationToken? = nil,
        runID: UUID? = nil,
        byteCount: Int64? = nil,
        schedulesDataTransfer: Bool = false,
        concurrencyPermit: SFTPConcurrencyPermit? = nil,
        operation: @escaping @Sendable (any SFTPClientProtocol) async throws -> Value
    ) async throws -> Value {
        let ownedPermit: SFTPConcurrencyPermit?
        if schedulesDataTransfer, concurrencyPermit == nil {
            ownedPermit = try await pool.sftpConcurrencyScheduler.acquire(
                anchorHostID: hostID,
                hostIDs: [hostID],
                source: .agentRun(runID ?? invocationID),
                byteCount: byteCount
            )
        } else {
            ownedPermit = nil
        }
        let permit = concurrencyPermit ?? ownedPermit
        do {
            let value = try await withSession(
                hostID: hostID, invocationID: invocationID, interaction: interaction
            ) { authentication in
                let lease = try await self.openAuthenticated(
                    hostID: hostID, authentication: authentication, pool: pool, kind: .sftp,
                    evictsPooledConnection: false, cancellation: cancellation
                ) { attempt in
                    let resolver: AgentConnectionPool.RequestResolving?
                    if let attempt {
                        let request = attempt.request
                        resolver = { _ in request }
                    } else {
                        resolver = nil
                    }
                    return try await pool.acquireSFTP(
                        hostID: hostID, cancellation: cancellation,
                        configuration: resolver,
                        mode: permit?.schedulingMode ?? .channelsOnly)
                }
                do {
                    let value = try await operation(lease.client)
                    await pool.releaseSFTP(lease.id)
                    return value
                } catch {
                    await pool.releaseSFTP(lease.id)
                    if let failure = error as? SFTPError {
                        switch failure {
                        case .notConnected, .connectionLost:
                            await pool.disconnect(hostID: hostID, kind: .sftp)
                        case .cancelled, .localFile, .operation:
                            break
                        }
                    }
                    throw error
                }
            }
            await ownedPermit?.release()
            return value
        } catch {
            await ownedPermit?.release()
            throw error
        }
    }

    private func openAuthenticated<Client: Sendable>(
        hostID: Host.ID, authentication: AgentSSHConfigurationSession,
        pool: AgentConnectionPool, kind: AgentConnectionPool.Kind,
        evictsPooledConnection: Bool = true,
        cancellation: TransferCancellationToken? = nil,
        open: @Sendable (AgentSSHConfigurationSession.Attempt?) async throws -> Client
    ) async throws -> Client {
        var attempt: AgentSSHConfigurationSession.Attempt?
        if await authentication.canResolveTarget() {
            attempt = try await authentication.configurationAttempt()
        }
        while true {
            try Task.checkCancellation()
            if cancellation?.isCancelled == true { throw SFTPError.cancelled }
            let attemptedGeneration: UInt64
            if let attempt {
                attemptedGeneration = attempt.generation
            } else {
                attemptedGeneration = await authentication.currentGeneration
            }
            do {
                return try await open(attempt)
            } catch let error as TermindSSHError where error.shouldRequestAuthentication {
                if cancellation?.isCancelled == true { throw SFTPError.cancelled }
                if evictsPooledConnection { await pool.disconnect(hostID: hostID, kind: kind) }
                await authentication.retry(after: error, generation: attemptedGeneration)
                attempt = try await authentication.configurationAttempt()
            } catch let error as TermindSSHError where error.isLocalAuthenticationRequirement {
                attempt = try await authentication.configurationAttempt()
            }
        }
    }

    fileprivate func withSession<Value: Sendable>(
        hostID: Host.ID, invocationID: AgentToolInvocation.ID,
        interaction: AgentSSHInteraction,
        operation: @Sendable (AgentSSHConfigurationSession) async throws -> Value
    ) async throws -> Value {
        let token: UUID
        let session: AgentSSHConfigurationSession
        if var entry = entries[hostID] {
            entry.leases += 1
            entries[hostID] = entry
            token = entry.token
            session = entry.session
        } else {
            token = UUID()
            session = AgentSSHConfigurationSession(
                resolver: resolver, hostID: hostID, invocationID: invocationID,
                interaction: interaction
            )
            entries[hostID] = Entry(token: token, session: session, leases: 1)
        }
        defer { release(hostID: hostID, token: token) }
        return try await operation(session)
    }

    private func release(hostID: Host.ID, token: UUID) {
        guard var entry = entries[hostID], entry.token == token else { return }
        entry.leases -= 1
        if entry.leases == 0 {
            entries[hostID] = nil
        } else {
            entries[hostID] = entry
        }
    }
}

/// Keeps one Channel-multiplexed SSH-exec transport and a connection-preferred
/// SFTP group per Host alive across tool calls, runs, and conversations.
///
/// Before this existed, `ssh_exec` paid a full TCP connect, handshake, host-key
/// check, and signature for *every command* — and a jump-host route rebuilt
/// every hop each time. Keying by host rather than by run is what lets a
/// follow-up message reuse the connection; the idle sweep, not the end of a run,
/// is what gives it back.
///
/// Exec and SFTP remain separate lifecycle domains. Exec never opens a second
/// transport; SFTP data permits resolve their topology from the process-wide
/// preference, while control work and Channel fallback use the primary transport.
public actor AgentConnectionPool {
    public nonisolated static let execSchedulingMode = SSHChannelSchedulingMode.channelsOnly
    public nonisolated let sftpConcurrencyScheduler: SFTPConcurrencyScheduler

    public nonisolated enum Kind: String, Hashable, Sendable, CaseIterable { case exec, sftp }

    public typealias ConfigurationResolving =
        @Sendable (UUID) async throws -> SSHConnectionConfiguration
    public typealias RequestResolving =
        @Sendable (UUID) async throws -> SSHConnectionRequest
    public typealias FingerprintResolving = @Sendable (UUID) async throws -> String
    public typealias ExecOpening =
        @Sendable (SSHConnectionRequest) async throws -> any SSHExecSessionProtocol
    public typealias SFTPOpening =
        @Sendable (SSHConnectionRequest) async throws -> any SFTPClientProtocol

    /// Long enough that a user reading output and asking a follow-up keeps the
    /// connection, short enough that walking away does not leave an
    /// authenticated session open on a server indefinitely.
    public static let defaultIdleTimeout = Duration.seconds(180)

    private enum Client: Sendable {
        case exec(any SSHExecSessionProtocol)
        case sftp(any SFTPClientProtocol)

        public func disconnect() async {
            switch self {
            case .exec(let session): await session.disconnect()
            case .sftp(let client): await client.disconnect()
            }
        }
    }

    private struct Key: Hashable {
        var hostID: UUID
        var kind: Kind
    }

    private struct Entry {
        var client: Client
        var fingerprint: String
        var lastUsedAt: ContinuousClock.Instant
    }

    private struct InFlight {
        var fingerprint: String
        var task: Task<Client, any Error>
    }

    private let configuration: ConfigurationResolving
    private let routeFingerprint: FingerprintResolving
    private let openExec: ExecOpening
    private let openSFTP: SFTPOpening
    private let idleTimeout: Duration
    private let sweeper: AgentIdleSweeper
    private var entries: [Key: Entry] = [:]
    private var pending: [Key: InFlight] = [:]
    private var activeExecLeases: [Key: Int] = [:]

    struct SFTPLease: Sendable {
        fileprivate var id: UUID
        var client: any SFTPClientProtocol
    }

    private enum SFTPCapability { case unknown, connections, channels }

    private struct SFTPRecord {
        var id: UUID
        var client: any SFTPClientProtocol
        var busy: Bool
        var lastUsedAt: ContinuousClock.Instant
    }

    private struct SFTPState {
        var fingerprint: String
        var primaryID: UUID
        var records: [UUID: SFTPRecord]
        var capability = SFTPCapability.unknown
    }

    private struct ActiveSFTPLease {
        var hostID: UUID
        var recordID: UUID?
        var client: any SFTPClientProtocol
        var cancellation: TransferCancellationToken?
    }

    private struct SFTPProbe {
        var id: UUID
        var task: Task<any SFTPClientProtocol, any Error>
    }

    private var sftpStates: [UUID: SFTPState] = [:]
    private var activeSFTPLeases: [UUID: ActiveSFTPLease] = [:]
    private var sftpProbes: [UUID: SFTPProbe] = [:]
    /// Acquires one exclusive Agent SFTP client. Overlap prefers another SSH
    /// connection; after silent connection setup fails, it opens a sibling
    /// SFTP Channel on the primary transport instead.
    func acquireSFTP(
        hostID: UUID, cancellation: TransferCancellationToken? = nil,
        configuration override: RequestResolving? = nil,
        mode: SSHChannelSchedulingMode = .connectionsPreferred
    ) async throws -> SFTPLease {
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw SFTPError.cancelled }

        let fingerprint = try await routeFingerprint(hostID)
        if let state = sftpStates[hostID], state.fingerprint != fingerprint {
            _ = await disconnectSFTPState(hostID: hostID)
        }

        let primary = try await sftp(hostID: hostID, configuration: override)
        let committedFingerprint = try await routeFingerprint(hostID)
        if sftpStates[hostID] == nil {
            let record = SFTPRecord(id: UUID(), client: primary, busy: false, lastUsedAt: .now)
            sftpStates[hostID] = SFTPState(
                fingerprint: committedFingerprint, primaryID: record.id,
                records: [record.id: record])
        }

        if let idle = sftpStates[hostID]?.records.values
            .filter({ !$0.busy && (mode == .connectionsPreferred || $0.id == sftpStates[hostID]?.primaryID) })
            .sorted(by: { $0.lastUsedAt < $1.lastUsedAt }).first
        {
            sftpStates[hostID]?.records[idle.id]?.busy = true
            return registerSFTPLease(
                hostID: hostID, recordID: idle.id, client: idle.client,
                cancellation: cancellation)
        }

        guard let state = sftpStates[hostID], let primaryRecord = state.records[state.primaryID] else {
            throw SFTPError.notConnected
        }

        if mode == .channelsOnly {
            do {
                let sibling = try await primaryRecord.client.openSiblingChannel()
                if cancellation?.isCancelled == true {
                    await sibling.disconnect()
                    throw SFTPError.cancelled
                }
                return registerSFTPLease(
                    hostID: hostID, recordID: nil, client: sibling, cancellation: cancellation)
            } catch {
                try Task.checkCancellation()
                if cancellation?.isCancelled == true { throw SFTPError.cancelled }
                if error is CancellationError { throw error }
                if let failure = error as? SFTPError, case .cancelled = failure { throw failure }
                while sftpStates[hostID]?.records[primaryRecord.id]?.busy == true {
                    try await Task.sleep(for: .milliseconds(10))
                    try Task.checkCancellation()
                    if cancellation?.isCancelled == true { throw SFTPError.cancelled }
                }
                return try await acquireSFTP(
                    hostID: hostID, cancellation: cancellation,
                    configuration: override, mode: mode)
            }
        }

        if state.capability == .unknown {
            let probe: SFTPProbe
            if let existing = sftpProbes[hostID] {
                probe = existing
            } else {
                let id = UUID()
                let task = Task { [configuration, openSFTP] () async throws -> any SFTPClientProtocol in
                    let durable = try await configuration(hostID)
                    let request = SSHConnectionRequest(
                        configuration: durable, interactionPolicy: .forbidden
                    ).enforcingInteractionPolicy()
                    return try await openSFTP(request)
                }
                probe = SFTPProbe(id: id, task: task)
                sftpProbes[hostID] = probe
            }
            do {
                let client = try await probe.task.value
                if sftpProbes[hostID]?.id == probe.id {
                    sftpProbes[hostID] = nil
                    let record = SFTPRecord(id: UUID(), client: client, busy: false, lastUsedAt: .now)
                    sftpStates[hostID]?.records[record.id] = record
                    sftpStates[hostID]?.capability = .connections
                }
                return try await acquireSFTP(
                    hostID: hostID, cancellation: cancellation,
                    configuration: override, mode: mode)
            } catch {
                if sftpProbes[hostID]?.id == probe.id {
                    sftpProbes[hostID] = nil
                    sftpStates[hostID]?.capability = .channels
                }
                if error is CancellationError { throw error }
                if let failure = error as? SFTPError, case .cancelled = failure { throw failure }
            }
        } else if state.capability == .connections {
            do {
                let durable = try await configuration(hostID)
                let request = SSHConnectionRequest(
                    configuration: durable, interactionPolicy: .forbidden
                ).enforcingInteractionPolicy()
                let client = try await openSFTP(request)
                try Task.checkCancellation()
                if cancellation?.isCancelled == true {
                    await client.disconnect()
                    throw SFTPError.cancelled
                }
                let record = SFTPRecord(id: UUID(), client: client, busy: true, lastUsedAt: .now)
                sftpStates[hostID]?.records[record.id] = record
                sftpStates[hostID]?.capability = .connections
                startSweeping()
                return registerSFTPLease(
                    hostID: hostID, recordID: record.id, client: client,
                    cancellation: cancellation)
            } catch {
                if error is CancellationError { throw error }
                if let failure = error as? SFTPError, case .cancelled = failure { throw failure }
                sftpStates[hostID]?.capability = .channels
            }
        }

        let sibling = try await primaryRecord.client.openSiblingChannel()
        if cancellation?.isCancelled == true {
            await sibling.disconnect()
            throw SFTPError.cancelled
        }
        return registerSFTPLease(
            hostID: hostID, recordID: nil, client: sibling, cancellation: cancellation)
    }

    func releaseSFTP(_ id: UUID) async {
        guard let lease = activeSFTPLeases.removeValue(forKey: id) else { return }
        if let recordID = lease.recordID, sftpStates[lease.hostID]?.records[recordID] != nil {
            sftpStates[lease.hostID]?.records[recordID]?.busy = false
            sftpStates[lease.hostID]?.records[recordID]?.lastUsedAt = .now
        } else {
            await lease.client.disconnect()
        }
    }

    private func registerSFTPLease(
        hostID: UUID, recordID: UUID?, client: any SFTPClientProtocol,
        cancellation: TransferCancellationToken?
    ) -> SFTPLease {
        let id = UUID()
        activeSFTPLeases[id] = ActiveSFTPLease(
            hostID: hostID, recordID: recordID, client: client, cancellation: cancellation)
        startSweeping()
        return SFTPLease(id: id, client: client)
    }

    public init(
        configuration: @escaping ConfigurationResolving,
        routeFingerprint: @escaping FingerprintResolving,
        openExec: @escaping ExecOpening,
        openSFTP: @escaping SFTPOpening,
        sftpConcurrencyScheduler: SFTPConcurrencyScheduler = SFTPConcurrencyScheduler(),
        idleTimeout: Duration = AgentConnectionPool.defaultIdleTimeout,
        sweepInterval: Duration? = .seconds(30)
    ) {
        self.configuration = configuration
        self.routeFingerprint = routeFingerprint
        self.openExec = openExec
        self.openSFTP = openSFTP
        self.sftpConcurrencyScheduler = sftpConcurrencyScheduler
        self.idleTimeout = idleTimeout
        sweeper = AgentIdleSweeper(interval: sweepInterval)
    }

    /// Runs one command on the host's pooled session, opening one if needed.
    ///
    /// Retries exactly once only when the pooled transport was already gone
    /// before a Channel could open. A server-side Channel rejection stays on
    /// the one-transport policy and is surfaced; anything that failed after the
    /// command started is also surfaced because replay could duplicate effects.
    public func execute(
        _ command: String, workingDirectory: String?, stdin: Data?,
        timeout: TimeInterval, outputLimit: Int, hostID: UUID,
        configuration override: RequestResolving? = nil,
        onOutput: SSHExecOutputHandler? = nil
    ) async throws -> SSHExecResult {
        do {
            let session = try await exec(hostID: hostID, configuration: override)
            return try await withExecLease(hostID: hostID, session: session) {
                try await session.execute(
                    command, workingDirectory: workingDirectory, stdin: stdin,
                    timeout: timeout, outputLimit: outputLimit, onOutput: onOutput)
            }
        } catch SSHExecSessionError.transportUnavailable {
            await disconnect(hostID: hostID, kind: .exec)
            let session = try await exec(hostID: hostID, configuration: override)
            return try await withExecLease(hostID: hostID, session: session) {
                try await session.execute(
                    command, workingDirectory: workingDirectory, stdin: stdin,
                    timeout: timeout, outputLimit: outputLimit, onOutput: onOutput)
            }
        }
    }

    func withExecLease<Value: Sendable>(
        hostID: UUID, session: any SSHExecSessionProtocol,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let key = Key(hostID: hostID, kind: .exec)
        guard case .exec(let pooled)? = entries[key]?.client, pooled === session else {
            throw SSHExecSessionError.transportUnavailable(TermindSSHError.disconnected)
        }
        activeExecLeases[key, default: 0] += 1
        defer {
            let remaining = (activeExecLeases[key] ?? 1) - 1
            activeExecLeases[key] = remaining == 0 ? nil : remaining
            if var entry = entries[key] {
                entry.lastUsedAt = .now
                entries[key] = entry
            }
        }
        return try await operation()
    }

    public func exec(
        hostID: UUID, configuration override: RequestResolving? = nil
    ) async throws -> any SSHExecSessionProtocol {
        guard
            case .exec(let session) = try await resolve(
                hostID: hostID, kind: .exec, configuration: override
            )
        else { throw AgentToolError.invalidHost }
        return session
    }

    public func sftp(
        hostID: UUID, configuration override: RequestResolving? = nil
    ) async throws -> any SFTPClientProtocol {
        guard
            case .sftp(let client) = try await resolve(
                hostID: hostID, kind: .sftp, configuration: override
            )
        else { throw AgentToolError.invalidHost }
        if sftpStates[hostID] == nil {
            let record = SFTPRecord(id: UUID(), client: client, busy: false, lastUsedAt: .now)
            sftpStates[hostID] = SFTPState(
                fingerprint: try await routeFingerprint(hostID), primaryID: record.id,
                records: [record.id: record])
            startSweeping()
        }
        return client
    }

    /// Reports whether anything was actually open, which is what lets callers
    /// treat closing an already-closed host as a no-op rather than a failure.
    @discardableResult
    public func disconnect(hostID: UUID, kind: Kind) async -> Bool {
        if kind == .sftp {
            let stateClosed = await disconnectSFTPState(hostID: hostID)
            guard let entry = entries.removeValue(forKey: Key(hostID: hostID, kind: kind)) else {
                stopSweepingIfEmpty()
                return stateClosed
            }
            // A primary installed in the scheduler state was already closed.
            if !stateClosed { await entry.client.disconnect() }
            stopSweepingIfEmpty()
            return true
        }
        let key = Key(hostID: hostID, kind: kind)
        guard let entry = entries.removeValue(forKey: key) else { return false }
        activeExecLeases[key] = nil
        stopSweepingIfEmpty()
        await entry.client.disconnect()
        return true
    }

    private func disconnectSFTPState(hostID: UUID) async -> Bool {
        sftpProbes.removeValue(forKey: hostID)?.task.cancel()
        let leaseIDs = activeSFTPLeases.filter { $0.value.hostID == hostID }.map(\.key)
        for id in leaseIDs { activeSFTPLeases[id]?.cancellation?.cancel() }
        let leases = leaseIDs.compactMap { activeSFTPLeases.removeValue(forKey: $0) }
        let state = sftpStates.removeValue(forKey: hostID)
        var seen: Set<ObjectIdentifier> = []
        for record in state?.records.values ?? [UUID: SFTPRecord]().values {
            let identity = ObjectIdentifier(record.client as AnyObject)
            if seen.insert(identity).inserted { await record.client.disconnect() }
        }
        for lease in leases where lease.recordID == nil { await lease.client.disconnect() }
        return state != nil || !leases.isEmpty
    }

    @discardableResult
    public func disconnect(hostID: UUID) async -> Bool {
        var closed = false
        for kind in Kind.allCases {
            closed = await disconnect(hostID: hostID, kind: kind) || closed
        }
        return closed
    }

    public func closeAll() async {
        for probe in sftpProbes.values { probe.task.cancel() }
        sftpProbes.removeAll()
        let sftpHostIDs = Array(sftpStates.keys)
        for hostID in sftpHostIDs { _ = await disconnectSFTPState(hostID: hostID) }
        let closing = entries.filter { $0.key.kind != .sftp }.map(\.value.client)
        entries.removeAll()
        activeExecLeases.removeAll()
        stopSweepingIfEmpty()
        for client in closing { await client.disconnect() }
    }

    /// Closes everything untouched for longer than the idle timeout and reports
    /// how many connections remain. Driven by a background task in the app and
    /// called directly, with a synthetic instant, by tests.
    @discardableResult
    public func sweepIdle(now: ContinuousClock.Instant) async -> Int {
        let expired = entries.filter {
            $0.key.kind != .sftp && activeExecLeases[$0.key] == nil
                && now - $0.value.lastUsedAt >= idleTimeout
        }
        for key in expired.keys { entries[key] = nil }
        var expiredSFTP: [(UUID, SFTPRecord)] = []
        for hostID in Array(sftpStates.keys) {
            guard var state = sftpStates[hostID] else { continue }
            for (id, record) in state.records
            where id != state.primaryID && !record.busy && now - record.lastUsedAt >= idleTimeout {
                state.records[id] = nil
                expiredSFTP.append((hostID, record))
            }
            if let primary = state.records[state.primaryID], state.records.count == 1,
                !primary.busy, now - primary.lastUsedAt >= idleTimeout
            {
                state.records[state.primaryID] = nil
                expiredSFTP.append((hostID, primary))
            }
            if state.records.isEmpty {
                sftpStates[hostID] = nil
                entries[Key(hostID: hostID, kind: .sftp)] = nil
            } else {
                sftpStates[hostID] = state
            }
        }
        stopSweepingIfEmpty()
        for entry in expired.values { await entry.client.disconnect() }
        for (_, record) in expiredSFTP { await record.client.disconnect() }
        return openConnectionCount
    }

    public func isConnected(hostID: UUID, kind: Kind) -> Bool {
        if kind == .sftp { return sftpStates[hostID]?.records.isEmpty == false }
        return entries[Key(hostID: hostID, kind: kind)] != nil
    }

    public var openConnectionCount: Int {
        entries.filter { $0.key.kind != .sftp }.count
            + sftpStates.values.reduce(0) { $0 + $1.records.count }
    }

    private func resolve(
        hostID: UUID, kind: Kind, configuration override: RequestResolving?
    ) async throws -> Client {
        let fingerprint: String
        do {
            fingerprint = try await routeFingerprint(hostID)
        } catch {
            // The host is gone — deleted from the Vault, or a temporary target
            // whose pane closed. Do not keep a session to it alive.
            await disconnect(hostID: hostID)
            throw error
        }
        let key = Key(hostID: hostID, kind: kind)
        if let entry = entries.removeValue(forKey: key) {
            guard entry.fingerprint == fingerprint else {
                // Nothing waits on a stale socket. Its worker also frees the
                // libssh2 session in `deinit`, so dropping the reference alone
                // would be safe; this just makes it prompt.
                Task { await entry.client.disconnect() }
                return try await open(
                    key: key, fingerprint: fingerprint, configuration: override
                )
            }
            entries[key] = Entry(
                client: entry.client, fingerprint: fingerprint, lastUsedAt: .now
            )
            return entry.client
        }
        return try await open(key: key, fingerprint: fingerprint, configuration: override)
    }

    private func open(
        key: Key, fingerprint: String, configuration override: RequestResolving?
    ) async throws -> Client {
        // Without this join, two tool calls that both miss the cache would each
        // build a connection and one of them would never be pooled — or closed.
        if let inFlight = pending[key], inFlight.fingerprint == fingerprint {
            let client = try await inFlight.task.value
            let committedFingerprint = try await routeFingerprint(key.hostID)
            commit(client, key: key, fingerprint: committedFingerprint)
            return client
        }
        let task = Task { [configuration, openExec, openSFTP] () async throws -> Client in
            let request: SSHConnectionRequest
            if let override {
                request = try await override(key.hostID)
            } else {
                request = SSHConnectionRequest(
                    configuration: try await configuration(key.hostID)
                )
            }
            switch key.kind {
            case .exec: return .exec(try await openExec(request))
            case .sftp: return .sftp(try await openSFTP(request))
            }
        }
        pending[key] = InFlight(fingerprint: fingerprint, task: task)
        defer { if pending[key]?.fingerprint == fingerprint { pending[key] = nil } }
        // Committed on every path that receives a client, not only on the path
        // that started the task: whoever started it may have been cancelled
        // while a second caller was still waiting on the same connection.
        let client = try await task.value
        // Saving/binding an Identity while the connection prompt is open
        // legitimately changes the route fingerprint. Bind the authenticated
        // session to that post-save route so the next command can reuse it.
        let committedFingerprint = try await routeFingerprint(key.hostID)
        commit(client, key: key, fingerprint: committedFingerprint)
        return client
    }

    private func commit(_ client: Client, key: Key, fingerprint: String) {
        entries[key] = Entry(client: client, fingerprint: fingerprint, lastUsedAt: .now)
        startSweeping()
    }

    private func startSweeping() {
        sweeper.start { [weak self] in
            guard let self else { return 0 }
            return await self.sweepIdle(now: .now)
        }
    }

    private func stopSweepingIfEmpty() {
        guard entries.isEmpty, pending.isEmpty, sftpStates.isEmpty, activeSFTPLeases.isEmpty,
            sftpProbes.isEmpty
        else { return }
        sweeper.stop()
    }
}
