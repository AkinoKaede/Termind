import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure

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
                case .cancelled:
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
        var host: Host
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
                return AuthenticationRequirement(host: host, mode: .passphrase(keyID: keyID))
            }
            if submission.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (submission.keyID == nil && submission.password == nil)
            {
                return AuthenticationRequirement(host: host, mode: .identity)
            }
            if forcedHostID == host.id {
                return AuthenticationRequirement(host: host, mode: .identity)
            }
            return nil
        }
        guard let identity = store.identity(for: host) else {
            return AuthenticationRequirement(host: host, mode: .identity)
        }
        let resolution = store.sshCredentials(for: identity)
        if let keyID = resolution.requiredPassphraseKeyID {
            return AuthenticationRequirement(host: host, mode: .passphrase(keyID: keyID))
        }
        if identity.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || resolution.credentials.isEmpty
        {
            return AuthenticationRequirement(host: host, mode: .identity)
        }
        if forcedHostID == host.id {
            return AuthenticationRequirement(host: host, mode: .identity)
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
            let password = try store.passwordCredential(for: identity)
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

    private func openAuthenticated<Client: Sendable>(
        hostID: Host.ID, authentication: AgentSSHConfigurationSession,
        pool: AgentConnectionPool, kind: AgentConnectionPool.Kind,
        open: @Sendable (AgentSSHConfigurationSession.Attempt?) async throws -> Client
    ) async throws -> Client {
        var attempt: AgentSSHConfigurationSession.Attempt?
        if await authentication.canResolveTarget() {
            attempt = try await authentication.configurationAttempt()
        }
        while true {
            let attemptedGeneration: UInt64
            if let attempt {
                attemptedGeneration = attempt.generation
            } else {
                attemptedGeneration = await authentication.currentGeneration
            }
            do {
                return try await open(attempt)
            } catch let error as TermindSSHError where error.shouldRequestAuthentication {
                await pool.disconnect(hostID: hostID, kind: kind)
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

/// Keeps one authenticated SSH-exec session and one SFTP session per host alive
/// across tool calls, runs, and conversations.
///
/// Before this existed, `ssh_exec` paid a full TCP connect, handshake, host-key
/// check, and signature for *every command* — and a jump-host route rebuilt
/// every hop each time. Keying by host rather than by run is what lets a
/// follow-up message reuse the connection; the idle sweep, not the end of a run,
/// is what gives it back.
///
/// Exec and SFTP stay on separate sessions so one long-running command cannot
/// block a directory listing. That is at most two connections per host, against
/// one per command before.
public actor AgentConnectionPool {
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

    public init(
        configuration: @escaping ConfigurationResolving,
        routeFingerprint: @escaping FingerprintResolving,
        openExec: @escaping ExecOpening,
        openSFTP: @escaping SFTPOpening,
        idleTimeout: Duration = AgentConnectionPool.defaultIdleTimeout,
        sweepInterval: Duration? = .seconds(30)
    ) {
        self.configuration = configuration
        self.routeFingerprint = routeFingerprint
        self.openExec = openExec
        self.openSFTP = openSFTP
        self.idleTimeout = idleTimeout
        sweeper = AgentIdleSweeper(interval: sweepInterval)
    }

    /// Runs one command on the host's pooled session, opening one if needed.
    ///
    /// Retries exactly once, and only on `channelUnavailable` — the failure that
    /// is thrown while the command is provably not running. A pooled session
    /// that died quietly between commands is invisible to the caller; anything
    /// that failed *after* the command started is surfaced, because re-running
    /// half of an `rm` is worse than a failed tool call.
    public func execute(
        _ command: String, workingDirectory: String?, stdin: Data?,
        timeout: TimeInterval, outputLimit: Int, hostID: UUID,
        configuration override: RequestResolving? = nil,
        onOutput: SSHExecOutputHandler? = nil
    ) async throws -> SSHExecResult {
        do {
            return try await exec(hostID: hostID, configuration: override).execute(
                command, workingDirectory: workingDirectory, stdin: stdin,
                timeout: timeout, outputLimit: outputLimit, onOutput: onOutput
            )
        } catch SSHExecSessionError.channelUnavailable {
            await disconnect(hostID: hostID, kind: .exec)
            return try await exec(hostID: hostID, configuration: override).execute(
                command, workingDirectory: workingDirectory, stdin: stdin,
                timeout: timeout, outputLimit: outputLimit, onOutput: onOutput
            )
        }
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
        return client
    }

    /// Gives a session away without closing it.
    ///
    /// For a command that outlived the turn that started it: the channel is
    /// still being pumped, so the session cannot be shared or swept, but it
    /// also must not be torn down. The pool forgets it and the next command for
    /// this host opens a fresh one — the same reconnect a timeout already
    /// forces today, except the output survives.
    public func detachExec(hostID: UUID, session: any SSHExecSessionProtocol) {
        let key = Key(hostID: hostID, kind: .exec)
        // By identity, because the pool may have opened a replacement for this
        // host in the meantime, and evicting *that* would give away a session
        // somebody else is about to use.
        guard case .exec(let pooled)? = entries[key]?.client, pooled === session else { return }
        entries.removeValue(forKey: key)
        stopSweepingIfEmpty()
    }

    /// Reports whether anything was actually open, which is what lets callers
    /// treat closing an already-closed host as a no-op rather than a failure.
    @discardableResult
    public func disconnect(hostID: UUID, kind: Kind) async -> Bool {
        guard let entry = entries.removeValue(forKey: Key(hostID: hostID, kind: kind))
        else { return false }
        stopSweepingIfEmpty()
        await entry.client.disconnect()
        return true
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
        let closing = entries.values.map(\.client)
        entries.removeAll()
        stopSweepingIfEmpty()
        for client in closing { await client.disconnect() }
    }

    /// Closes everything untouched for longer than the idle timeout and reports
    /// how many connections remain. Driven by a background task in the app and
    /// called directly, with a synthetic instant, by tests.
    @discardableResult
    public func sweepIdle(now: ContinuousClock.Instant) async -> Int {
        let expired = entries.filter { now - $0.value.lastUsedAt >= idleTimeout }
        for key in expired.keys { entries[key] = nil }
        stopSweepingIfEmpty()
        for entry in expired.values { await entry.client.disconnect() }
        return entries.count
    }

    public func isConnected(hostID: UUID, kind: Kind) -> Bool {
        entries[Key(hostID: hostID, kind: kind)] != nil
    }

    public var openConnectionCount: Int { entries.count }

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
        guard entries.isEmpty, pending.isEmpty else { return }
        sweeper.stop()
    }
}
