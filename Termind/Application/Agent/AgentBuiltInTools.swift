import Foundation

nonisolated struct AgentHostTarget: Identifiable, Hashable, Sendable, Codable {
    var id: UUID
    var displayName: String
    var address: String
    var tags: [String]
    var connectionState: String
    var isTemporary: Bool
    var groupID: HostGroup.ID?
    var groupPath: String?
}

nonisolated struct AgentHostGroupTarget: Identifiable, Hashable, Sendable {
    var id: HostGroup.ID
    var name: String
    var path: String
    var children: [AgentHostGroupTarget]
}

nonisolated struct AgentHostListing: Hashable, Sendable {
    var groups: [AgentHostGroupTarget]
    var hosts: [AgentHostTarget]
}

/// Main-actor bridge over the Vault. The Agent receives only public host
/// metadata; Keychain material is resolved directly into SSH configuration and
/// never serialized into a tool result.
@MainActor
final class AgentHostResolver: Sendable {
    private let store: HostStore
    private var temporaryTargets: @MainActor @Sendable () -> [AgentHostTarget]
    private var temporaryConfiguration:
        @MainActor @Sendable (UUID) throws -> SSHConnectionConfiguration?

    init(
        store: HostStore,
        temporaryTargets: @escaping @MainActor @Sendable () -> [AgentHostTarget] = { [] },
        temporaryConfiguration: @escaping
            @MainActor @Sendable (UUID) throws -> SSHConnectionConfiguration? = { _ in nil }
    ) {
        self.store = store
        self.temporaryTargets = temporaryTargets
        self.temporaryConfiguration = temporaryConfiguration
    }

    func configureTemporaryTargets(
        targets: @escaping @MainActor @Sendable () -> [AgentHostTarget],
        configuration: @escaping
            @MainActor @Sendable (UUID) throws -> SSHConnectionConfiguration?
    ) {
        temporaryTargets = targets
        temporaryConfiguration = configuration
    }

    func listing() -> AgentHostListing {
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
            hosts: saved + temporaryTargets().map { target in
                var target = target
                target.groupID = nil
                target.groupPath = nil
                return target
            }
        )
    }

    func targets() -> [AgentHostTarget] { listing().hosts }

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
        let roots = ordered(store.groups.filter { group in
            guard let parentID = group.parentID else { return true }
            return all[parentID] == nil
        })
        var result = roots.map { build($0, ancestors: []) }
        for group in ordered(store.groups) where !emitted.contains(group.id) {
            result.append(build(group, ancestors: []))
        }
        return result
    }

    func configuration(for id: UUID) throws -> SSHConnectionConfiguration {
        if let host = store.host(id) { return try store.sshConnectionConfiguration(for: host) }
        if let configuration = try temporaryConfiguration(id) { return configuration }
        throw AgentToolError.invalidHost
    }

    fileprivate struct InteractiveResolution: Sendable {
        var configuration: SSHConnectionConfiguration
        var submissions: [Host.ID: SSHAuthenticationSubmission]
    }

    /// Resolves every local authentication checkpoint in route order. The
    /// interaction handler receives public metadata and returns secrets
    /// directly to this main-actor bridge; none of it becomes tool content.
    fileprivate func interactiveConfiguration(
        for id: UUID,
        invocationID: AgentToolInvocation.ID,
        interaction: any AgentUserInteractionHandling,
        submissions initial: [Host.ID: SSHAuthenticationSubmission],
        forcedHostID initialForcedHostID: Host.ID? = nil,
        failure initialFailure: String? = nil
    ) async throws -> InteractiveResolution {
        guard let destination = store.host(id) else {
            // Pane-backed targets already carry a complete configuration and
            // cannot be saved back to the Vault from an Agent card.
            if let configuration = try temporaryConfiguration(id) {
                return InteractiveResolution(
                    configuration: configuration, submissions: initial
                )
            }
            throw AgentToolError.invalidHost
        }

        var submissions = initial
        var forcedHostID = initialForcedHostID
        var failure = initialFailure
        while let requirement = authenticationRequirement(
            for: destination, submissions: submissions, forcedHostID: forcedHostID
        ) {
            let node = requirement.host
            let existing = submissions[node.id]
            let identity = existing?.identityID.flatMap(store.identity)
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
            switch await interaction.requestSSHAuthentication(request) {
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

        return InteractiveResolution(
            configuration: try store.sshConnectionConfiguration(
                for: destination, submissions: submissions
            ),
            submissions: submissions
        )
    }

    private struct AuthenticationRequirement {
        var host: Host
        var mode: AgentSSHAuthenticationRequest.Mode
    }

    private func authenticationRequirement(
        for destination: Host,
        submissions: [Host.ID: SSHAuthenticationSubmission],
        forcedHostID: Host.ID?
    ) -> AuthenticationRequirement? {
        let route = store.route(for: destination)
        for node in route {
            guard forcedHostID == nil || forcedHostID == node.id else { continue }
            if let submission = submissions[node.id] {
                if let keyID = submission.keyID,
                    store.key(keyID)?.requiresPassphraseEntry == true,
                    submission.passphrase?.isEmpty != false
                {
                    return AuthenticationRequirement(host: node, mode: .passphrase(keyID: keyID))
                }
                if submission.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (submission.keyID == nil && submission.password == nil)
                {
                    return AuthenticationRequirement(host: node, mode: .identity)
                }
                if forcedHostID == node.id {
                    return AuthenticationRequirement(host: node, mode: .identity)
                }
                continue
            }
            guard let identity = store.identity(for: node) else {
                return AuthenticationRequirement(host: node, mode: .identity)
            }
            let resolution = store.sshCredentials(for: identity)
            if let keyID = resolution.requiredPassphraseKeyID {
                return AuthenticationRequirement(host: node, mode: .passphrase(keyID: keyID))
            }
            if identity.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || resolution.credentials.isEmpty
            {
                return AuthenticationRequirement(host: node, mode: .identity)
            }
            if forcedHostID == node.id {
                return AuthenticationRequirement(host: node, mode: .identity)
            }
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
    func routeFingerprint(for id: UUID) throws -> String {
        guard let host = store.host(id) else {
            // A pane-backed target has no Vault record to describe, and its
            // configuration is rebuilt from the live pane on every connect. Tie
            // the fingerprint to that pane still existing, so a closed tab
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

/// Keeps temporary credentials alive for exactly one command-opening journey,
/// including the pool's one safe reconnect. Once `ssh_exec` returns, this actor
/// and its cached configuration are released.
actor AgentSSHConfigurationSession {
    private let resolver: AgentHostResolver
    private let hostID: Host.ID
    private let invocationID: AgentToolInvocation.ID
    private let interaction: any AgentUserInteractionHandling
    private var submissions: [Host.ID: SSHAuthenticationSubmission] = [:]
    private var cached: SSHConnectionConfiguration?
    private var forcedHostID: Host.ID?
    private var failure: String?

    init(
        resolver: AgentHostResolver, hostID: Host.ID,
        invocationID: AgentToolInvocation.ID,
        interaction: any AgentUserInteractionHandling
    ) {
        self.resolver = resolver
        self.hostID = hostID
        self.invocationID = invocationID
        self.interaction = interaction
    }

    func configuration() async throws -> SSHConnectionConfiguration {
        if let cached { return cached }
        let resolution = try await resolver.interactiveConfiguration(
            for: hostID, invocationID: invocationID, interaction: interaction,
            submissions: submissions, forcedHostID: forcedHostID, failure: failure
        )
        submissions = resolution.submissions
        cached = resolution.configuration
        forcedHostID = nil
        failure = nil
        return resolution.configuration
    }

    func retry(after error: TermindSSHError) {
        let target = error.routeHostID ?? hostID
        if var retained = submissions[target] {
            retained.password = nil
            retained.passphrase = nil
            submissions[target] = retained
        }
        cached = nil
        forcedHostID = target
        failure = error.localizedDescription
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
actor AgentConnectionPool {
    nonisolated enum Kind: String, Hashable, Sendable, CaseIterable { case exec, sftp }

    typealias ConfigurationResolving =
        @Sendable (UUID) async throws -> SSHConnectionConfiguration
    typealias FingerprintResolving = @Sendable (UUID) async throws -> String
    typealias ExecOpening =
        @Sendable (SSHConnectionConfiguration) async throws -> any SSHExecSessionProtocol
    typealias SFTPOpening =
        @Sendable (SSHConnectionConfiguration) async throws -> any SFTPClientProtocol

    /// Long enough that a user reading output and asking a follow-up keeps the
    /// connection, short enough that walking away does not leave an
    /// authenticated session open on a server indefinitely.
    static let defaultIdleTimeout = Duration.seconds(180)

    private enum Client: Sendable {
        case exec(any SSHExecSessionProtocol)
        case sftp(any SFTPClientProtocol)

        func disconnect() async {
            switch self {
            case .exec(let session): await session.disconnect()
            case .sftp(let client): await client.disconnect()
            }
        }
    }

    private struct Key: Hashable { var hostID: UUID; var kind: Kind }

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
    private let sweepInterval: Duration?
    private var entries: [Key: Entry] = [:]
    private var pending: [Key: InFlight] = [:]
    private var sweeper: Task<Void, Never>?

    init(
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
        self.sweepInterval = sweepInterval
    }

    /// Runs one command on the host's pooled session, opening one if needed.
    ///
    /// Retries exactly once, and only on `channelUnavailable` — the failure that
    /// is thrown while the command is provably not running. A pooled session
    /// that died quietly between commands is invisible to the caller; anything
    /// that failed *after* the command started is surfaced, because re-running
    /// half of an `rm` is worse than a failed tool call.
    func execute(
        _ command: String, workingDirectory: String?, stdin: Data?,
        timeout: TimeInterval, outputLimit: Int, hostID: UUID,
        configuration override: ConfigurationResolving? = nil,
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

    func exec(
        hostID: UUID, configuration override: ConfigurationResolving? = nil
    ) async throws -> any SSHExecSessionProtocol {
        guard case .exec(let session) = try await resolve(
            hostID: hostID, kind: .exec, configuration: override
        )
        else { throw AgentToolError.invalidHost }
        return session
    }

    func sftp(hostID: UUID) async throws -> any SFTPClientProtocol {
        guard case .sftp(let client) = try await resolve(
            hostID: hostID, kind: .sftp, configuration: nil
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
    func detachExec(hostID: UUID, session: any SSHExecSessionProtocol) {
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
    func disconnect(hostID: UUID, kind: Kind) async -> Bool {
        guard let entry = entries.removeValue(forKey: Key(hostID: hostID, kind: kind))
        else { return false }
        stopSweepingIfEmpty()
        await entry.client.disconnect()
        return true
    }

    @discardableResult
    func disconnect(hostID: UUID) async -> Bool {
        var closed = false
        for kind in Kind.allCases {
            closed = await disconnect(hostID: hostID, kind: kind) || closed
        }
        return closed
    }

    func closeAll() async {
        let closing = entries.values.map(\.client)
        entries.removeAll()
        stopSweepingIfEmpty()
        for client in closing { await client.disconnect() }
    }

    /// Closes everything untouched for longer than the idle timeout and reports
    /// how many connections remain. Driven by a background task in the app and
    /// called directly, with a synthetic instant, by tests.
    @discardableResult
    func sweepIdle(now: ContinuousClock.Instant) async -> Int {
        let expired = entries.filter { now - $0.value.lastUsedAt >= idleTimeout }
        for key in expired.keys { entries[key] = nil }
        stopSweepingIfEmpty()
        for entry in expired.values { await entry.client.disconnect() }
        return entries.count
    }

    func isConnected(hostID: UUID, kind: Kind) -> Bool {
        entries[Key(hostID: hostID, kind: kind)] != nil
    }

    var openConnectionCount: Int { entries.count }

    private func resolve(
        hostID: UUID, kind: Kind, configuration override: ConfigurationResolving?
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
        key: Key, fingerprint: String, configuration override: ConfigurationResolving?
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
            let resolved = try await (override ?? configuration)(key.hostID)
            switch key.kind {
            case .exec: return .exec(try await openExec(resolved))
            case .sftp: return .sftp(try await openSFTP(resolved))
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
        guard sweeper == nil, let sweepInterval else { return }
        sweeper = Task { [weak self, sweepInterval] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: sweepInterval) } catch { return }
                guard let self, await self.sweepIdle(now: .now) > 0 else { return }
            }
        }
    }

    private func stopSweepingIfEmpty() {
        guard entries.isEmpty, pending.isEmpty else { return }
        sweeper?.cancel()
        sweeper = nil
    }
}

nonisolated enum AgentBuiltInTools: AgentToolSchemaBuilding {
    /// `search` is optional, and nil means the tool is not registered at all
    /// rather than registered and always failing. A model shown a `web_search`
    /// it cannot use spends a turn discovering that; a model not shown one
    /// reaches for `fetch` or asks, which is the behaviour we want when no
    /// backend is configured. It is also nil whenever the model has provider
    /// search of its own — see `AppModel.webSearchPlan`.
    static func make(
        hosts: AgentHostResolver,
        connections: AgentConnectionPool,
        background: AgentBackgroundCommands = AgentBackgroundCommands(),
        fetcher: RestrictedHTTPFetcher = RestrictedHTTPFetcher(),
        search: WebSearchClient? = nil
    ) -> [AnyAgentTool] {
        [
            listHosts(hosts), sshExec(hosts, connections, background),
            sshWait(background), terminalSuggest(),
            sftpList(connections), sftpStat(connections), sftpRead(connections),
            sftpWrite(connections), sftpMkdir(connections), sftpMove(connections),
            sftpChmod(connections), sftpDelete(connections), fetch(fetcher),
            requestUserInput(), requestUserSecret(),
        ] + (search.map { [webSearch($0)] } ?? [])
    }

    private static func listHosts(_ hosts: AgentHostResolver) -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "list_hosts", "List Vault and temporary Termind SSH targets without credentials.",
            properties: [:], required: [], target: .host, safety: .locallyReadOnly,
            concurrency: .parallel
        )) { invocation, _ in
            let listing = await hosts.listing()
            let rows = listing.hosts.map { target in
                AgentJSONValue.object([
                    "id": .string(target.id.uuidString), "display_name": .string(target.displayName),
                    "address": .string(target.address), "tags": .array(target.tags.map(AgentJSONValue.string)),
                    "connection_state": .string(target.connectionState),
                    "temporary": .bool(target.isTemporary),
                    "group_id": target.groupID.map { .string($0.uuidString) } ?? .null,
                    "group_path": target.groupPath.map(AgentJSONValue.string) ?? .null,
                ])
            }
            func groupJSON(_ group: AgentHostGroupTarget) -> AgentJSONValue {
                .object([
                    "id": .string(group.id.uuidString), "name": .string(group.name),
                    "path": .string(group.path),
                    "children": .array(group.children.map(groupJSON)),
                ])
            }
            return result(invocation, .object([
                "groups": .array(listing.groups.map(groupJSON)),
                "hosts": .array(rows),
            ]))
        }
    }

    /// How long `ssh_exec` waits before telling the model what it has.
    ///
    /// Short, and safe to be short only because expiry stopped being
    /// destructive. It used to throw, discard the session, and lose everything
    /// the command had printed — while the command itself carried on running on
    /// the host — so the default had to be generous enough that it rarely
    /// happened. Now it hands back the output and a handle, which makes a short
    /// deadline pure gain: turns end in seconds, and anything the user typed
    /// while waiting is delivered at the boundary that follows.
    private static let defaultReportingDeadline = 15

    /// The ceiling on how long a command may run at all, deadline or no. Matches
    /// the clamp the session's own pump applies.
    private static let maximumCommandLifetime: TimeInterval = 15 * 60

    /// The sink that turns captured output into progress on this call's card.
    private static func reporting(
        _ invocation: AgentToolInvocation,
        _ report: @escaping @Sendable (AgentToolResult) -> Void
    ) -> @Sendable (String, String) -> Void {
        { out, error in
            report(result(invocation, .object([
                "status": .string("running"),
                "stdout": .string(out), "stderr": .string(error),
            ])))
        }
    }

    private static func exitedResult(
        _ invocation: AgentToolInvocation, _ output: SSHExecResult
    ) -> AgentToolResult {
        result(invocation, .object([
            "status": .string("exited"),
            "stdout": .string(output.stdout), "stderr": .string(output.stderr),
            "exit_code": .number(Double(output.exitCode)),
            "signal": output.signal.map(AgentJSONValue.string) ?? .null,
            "stdout_truncated": .bool(output.stdoutTruncated),
            "stderr_truncated": .bool(output.stderrTruncated),
        ]), truncated: output.stdoutTruncated || output.stderrTruncated)
    }

    /// Picks up a command `ssh_exec` left running.
    ///
    /// Read-only and parallel: it looks at a buffer and a task, and touches the
    /// host not at all. While it waits, the command's output is redirected to
    /// *this* call's card — output belongs under whichever call is currently
    /// answering for it, never two at once and never none.
    private static func sshWait(_ background: AgentBackgroundCommands) -> AnyAgentTool {
        AnyAgentTool(
            descriptor: descriptor(
                "ssh_wait",
                "Wait for a command ssh_exec reported as still running, and return its output.",
                properties: [
                    "handle": string(max: 64),
                    "timeout_seconds": integer(min: 1, max: 900),
                ],
                required: ["handle"], target: .host, safety: .locallyReadOnly,
                concurrency: .parallel
            ),
            execute: { invocation, context in
                let arguments = try Arguments(invocation)
                guard let handle = UUID(uuidString: try arguments.string("handle")) else {
                    throw AgentToolError.invalidArguments("handle is not a valid handle.")
                }
                let outcome = try await background.wait(
                    handle,
                    timeout: .seconds(arguments.optionalInt("timeout_seconds") ?? 60),
                    reporting: reporting(invocation, context.report)
                )
                guard let exitCode = outcome.exitCode else {
                    return result(invocation, .object([
                        "status": .string("running"),
                        "handle": .string(handle.uuidString),
                        "stdout": .string(outcome.standardOut),
                        "stderr": .string(outcome.standardError),
                    ]))
                }
                return result(invocation, .object([
                    "status": .string("exited"),
                    "stdout": .string(outcome.standardOut),
                    "stderr": .string(outcome.standardError),
                    "exit_code": .number(Double(exitCode)),
                    "signal": outcome.signal.map(AgentJSONValue.string) ?? .null,
                ]))
            }
        )
    }

    private static func sshExec(
        _ hosts: AgentHostResolver, _ pool: AgentConnectionPool,
        _ background: AgentBackgroundCommands
    ) -> AnyAgentTool {
        let tool = descriptor(
            "ssh_exec", "Execute one command over a dedicated non-PTY SSH exec channel.",
            properties: [
                "host_id": string(), "command": string(max: 32_768), "cwd": string(max: 4_096),
                "timeout_seconds": integer(min: 1, max: 900), "stdin": string(max: 131_072),
                "secret_handle": string(), "stdin_purpose": string(max: 256),
            ], required: ["host_id", "command"], target: .host, safety: .requiresAuthorization
        )
        return AnyAgentTool(
            descriptor: tool,
            preflight: { invocation in
                var checked = invocation
                let arguments = try Arguments(invocation)
                checked.targetHostID = try arguments.uuid("host_id")
                let command = try arguments.string("command")
                if arguments.optionalString("stdin") != nil && arguments.optionalString("secret_handle") != nil {
                    throw AgentToolError.invalidArguments("stdin and secret_handle are mutually exclusive.")
                }
                let assessment = CommandRiskClassifier.assess(command)
                let safe = assessment.risk == .safe
                return AgentToolPreflight(
                    invocation: checked,
                    safety: safe ? .locallyReadOnly : .requiresAuthorization,
                    reasons: assessment.reasons,
                    // Whether a command may run beside another is a property of
                    // the command, not of `ssh_exec`, and it is decided by the
                    // same locally-proven evidence that just decided `safety`.
                    // A command the classifier cannot vouch for makes its whole
                    // turn serial, so nothing observes the host while it is
                    // being changed.
                    //
                    // The ceiling on what this buys is worth stating: commands
                    // aimed at one host queue behind each other inside
                    // `SSHExecSession` regardless, because a libssh2 session
                    // cannot be driven from two places at once. The win is
                    // several hosts at once, and host work overlapping `fetch`,
                    // `web_search`, and MCP.
                    concurrency: safe ? .parallel : .sequential
                )
            },
            execute: { invocation, context in
                let arguments = try Arguments(invocation)
                let hostID = try arguments.uuid("host_id")
                let command = try arguments.string("command")
                var input = arguments.optionalString("stdin").map { Data($0.utf8) }
                if let rawHandle = arguments.optionalString("secret_handle") {
                    guard let handleID = UUID(uuidString: rawHandle) else {
                        throw AgentToolError.invalidArguments("secret_handle is invalid.")
                    }
                    let purpose = try arguments.string("stdin_purpose")
                    let secret = try await context.secretBroker.consume(
                        SecretHandle(id: handleID),
                        matching: SecretBinding(
                            runID: context.runID, toolName: "ssh_exec", hostID: hostID,
                            purpose: purpose
                        )
                    )
                    input = Data(secret.utf8)
                }
                let authentication = AgentSSHConfigurationSession(
                    resolver: hosts, hostID: hostID, invocationID: invocation.id,
                    interaction: context.userInteraction
                )
                let interactiveConfiguration: AgentConnectionPool.ConfigurationResolving = { _ in
                    try await authentication.configuration()
                }
                // Live output, so a command that takes a minute is a card
                // filling in rather than a spinner. Reported, never returned:
                // the model is owed one result per call and gets it below.
                let stream = AgentCommandOutputStream(
                    report: reporting(invocation, context.report)
                )
                let cwd = arguments.optionalString("cwd")
                // A `let` copy, because the task below outlives this call and a
                // captured `var` would be shared mutable state across it.
                let stdin = input
                let deadline = Duration.seconds(
                    arguments.optionalInt("timeout_seconds") ?? defaultReportingDeadline
                )
                // Connecting is inside the deadline too. A hang is a hang
                // whether it is DNS, a jump host or a handshake, and a turn that
                // ends on time is what lets the user be heard at all.
                let handover = AgentCommandHandover()
                let running = Task { () async throws -> SSHExecResult in
                    var retriedDeadSession = false
                    while true {
                        let session: any SSHExecSessionProtocol
                        do {
                            session = try await pool.exec(
                                hostID: hostID, configuration: interactiveConfiguration
                            )
                        } catch let error as TermindSSHError
                            where error.shouldRequestAuthentication
                        {
                            // Authentication failed before an exec channel — and
                            // therefore before the command could run. It is safe
                            // to collect another credential and reopen; command
                            // errors never enter this path.
                            await pool.disconnect(hostID: hostID, kind: .exec)
                            await authentication.retry(after: error)
                            continue
                        }
                        // The call may already have given up while this was
                        // connecting. Starting anyway would leave a command
                        // running, printing and finishing with nobody holding a
                        // handle to it.
                        guard retriedDeadSession || handover.beginRunning(on: session) else {
                            throw AgentCommandNotStarted()
                        }
                        do {
                            return try await session.execute(
                                command, workingDirectory: cwd, stdin: stdin,
                                timeout: maximumCommandLifetime, outputLimit: 256 * 1_024,
                                onOutput: stream.handler
                            )
                        } catch SSHExecSessionError.channelUnavailable
                            where !retriedDeadSession
                        {
                            // A pooled session that died quietly between commands
                            // is invisible until it is used. Thrown only while the
                            // command is provably not running, so reopening cannot
                            // run half of an `rm` twice.
                            retriedDeadSession = true
                            await pool.disconnect(hostID: hostID, kind: .exec)
                        }
                    }
                }

                guard await AgentBackgroundCommands.settled(running, within: deadline) else {
                    guard let session = handover.giveUp() else {
                        // Still connecting, so there is nothing to hand over —
                        // no session, no output, no handle worth giving. The
                        // connection is left to finish into the pool rather than
                        // torn down, so the retry this invites is the fast one.
                        return result(invocation, .object([
                            "status": .string("connecting"),
                            "note": .string(String(
                                localized: """
                                    The host has not finished answering after \
                                    \(deadline.components.seconds)s, so the command has not \
                                    started. Nothing ran. The connection is still being set up; \
                                    running this again shortly is likely to be quick.
                                    """
                            )),
                        ]), truncated: false)
                    }
                    // It outlived its turn. The session goes with it — the
                    // channel is still being pumped, so it can be neither shared
                    // nor swept — and the next command for this host opens a
                    // fresh one.
                    await pool.detachExec(hostID: hostID, session: session)
                    let handle = await background.adopt(
                        hostID: hostID, command: command, stream: stream,
                        task: running, session: session,
                        // If the model never comes back for it, the outcome is
                        // pushed at the next model boundary instead of being
                        // swept ten minutes later unread.
                        announce: context.notify
                    )
                    let captured = stream.captured
                    return result(invocation, .object([
                        "status": .string("running"),
                        "handle": .string(handle.uuidString),
                        "stdout": .string(captured.standardOut),
                        "stderr": .string(captured.standardError),
                        "note": .string(String(
                            localized: """
                                Still running after \(deadline.components.seconds)s. The output \
                                above is what it has printed so far. Call ssh_wait with this \
                                handle for the rest; leaving it unasked-about abandons it.
                                """
                        )),
                    ]))
                }
                return exitedResult(invocation, try await running.value)
            }
        )
    }

    private static func terminalSuggest() -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "terminal_suggest", "Create a command card. Only the user can insert or run it in a PTY.",
            properties: ["command": string(max: 32_768), "explanation": string(max: 4_096)],
            required: ["command"], target: .user, safety: .locallyReadOnly,
            // It writes a card and touches nothing else. Whatever the command
            // would do if the user ran it is the user's action, later.
            concurrency: .parallel
        )) { invocation, _ in
            let arguments = try Arguments(invocation)
            let command = try arguments.string("command")
            guard !command.contains("\n"), !command.contains("\r"), !command.contains("\0") else {
                throw AgentToolError.invalidArguments("A terminal suggestion must be one command line.")
            }
            return result(invocation, .object([
                "command": .string(command),
                "explanation": .string(arguments.optionalString("explanation") ?? ""),
                "risk": .string(CommandRiskClassifier.assess(command).risk.label),
                "requires_user_action": .bool(true),
            ]))
        }
    }

    private static func sftpList(_ pool: AgentConnectionPool) -> AnyAgentTool {
        readOnlySFTP("sftp_list", "List a remote directory.", pool: pool) {
            client, path, invocation in
            let files = try await client.listDirectory(at: path)
            return result(invocation, .array(files.map(remoteFileJSON)))
        }
    }

    private static func sftpStat(_ pool: AgentConnectionPool) -> AnyAgentTool {
        readOnlySFTP("sftp_stat", "Read remote file metadata.", pool: pool) {
            client, path, invocation in
            guard let file = try await client.attributes(at: path) else {
                throw AgentToolError.notFound
            }
            return result(invocation, remoteFileJSON(file))
        }
    }

    private static func sftpRead(_ pool: AgentConnectionPool) -> AnyAgentTool {
        readOnlySFTP("sftp_read", "Read a bounded UTF-8 remote file inline.", pool: pool) {
            client, path, invocation in
            let data = try await client.readFile(at: path, maximumBytes: 128 * 1_024)
            guard let text = String(data: data, encoding: .utf8) else {
                throw AgentToolError.invalidArguments("The remote file is not UTF-8 text.")
            }
            return result(invocation, .object([
                "path": .string(path), "content": .string(text), "bytes": .number(Double(data.count)),
            ]))
        }
    }

    private static func sftpWrite(_ pool: AgentConnectionPool) -> AnyAgentTool {
        writeSFTP("sftp_write", "Write a bounded UTF-8 remote file atomically.", pool: pool,
            extra: ["content": string(max: 131_072), "overwrite": boolean()],
            extraRequired: ["content"]
        ) { client, path, arguments, invocation in
            try await client.writeFile(
                Data(try arguments.string("content").utf8), at: path,
                overwrite: arguments.optionalBool("overwrite") ?? false
            )
            return result(invocation, .object(["path": .string(path), "written": .bool(true)]))
        }
    }

    private static func sftpMkdir(_ pool: AgentConnectionPool) -> AnyAgentTool {
        writeSFTP("sftp_mkdir", "Create a remote directory.", pool: pool) {
            client, path, _, invocation in
            try await client.createDirectory(at: path)
            return result(invocation, .object(["path": .string(path), "created": .bool(true)]))
        }
    }

    private static func sftpMove(_ pool: AgentConnectionPool) -> AnyAgentTool {
        writeSFTP(
            "sftp_move", "Move or rename a remote path.", pool: pool,
            extra: ["destination": string(max: 4_096), "overwrite": boolean()],
            extraRequired: ["destination"]
        ) { client, path, arguments, invocation in
            let destination = try normalizeRemotePath(arguments.string("destination"))
            try await client.rename(
                from: path, to: destination,
                overwrite: arguments.optionalBool("overwrite") ?? false
            )
            return result(invocation, .object([
                "source": .string(path), "destination": .string(destination), "moved": .bool(true),
            ]))
        }
    }

    private static func sftpChmod(_ pool: AgentConnectionPool) -> AnyAgentTool {
        writeSFTP(
            "sftp_chmod", "Change remote POSIX permissions.", pool: pool,
            extra: ["mode": string(max: 4)], extraRequired: ["mode"]
        ) { client, path, arguments, invocation in
            let raw = try arguments.string("mode")
            guard (3...4).contains(raw.count), raw.allSatisfy({ ("0"..."7").contains(String($0)) }),
                let mode = UInt32(raw, radix: 8)
            else { throw AgentToolError.invalidArguments("mode must be a 3- or 4-digit octal value.") }
            try await client.setPermissions(at: path, to: mode)
            return result(invocation, .object(["path": .string(path), "mode": .string(raw)]))
        }
    }

    private static func sftpDelete(_ pool: AgentConnectionPool) -> AnyAgentTool {
        writeSFTP(
            "sftp_delete", "Permanently delete one remote file or empty directory.", pool: pool,
            extra: ["kind": enumeration(["file", "directory"])], extraRequired: ["kind"]
        ) { client, path, arguments, invocation in
            if try arguments.string("kind") == "directory" {
                try await client.removeDirectory(at: path)
            } else { try await client.removeFile(at: path) }
            return result(invocation, .object(["path": .string(path), "deleted": .bool(true)]))
        }
    }

    static func fetch(_ fetcher: RestrictedHTTPFetcher) -> AnyAgentTool {
        let header = object(
            properties: [
                "name": string(max: RestrictedHTTPHeaderValidator.maximumNameBytes),
                "value": string(max: RestrictedHTTPHeaderValidator.maximumValueBytes),
            ],
            required: ["name", "value"]
        )
        let tool = descriptor(
            "fetch",
            "Fetch bounded HTTP(S), including approved private-network targets. Custom headers "
                + "follow every redirect, including cross-origin redirects, like curl -H -L.",
            properties: [
                "url": string(max: 8_192), "method": enumeration(["GET", "HEAD"]),
                "headers": array(items: header, max: RestrictedHTTPHeaderValidator.maximumCount),
            ],
            required: ["url"], target: .network, safety: .locallyReadOnly,
            // GET and HEAD only, over separate connections, against a server
            // that already expects concurrency. This is where parallel tool
            // calls pay for themselves.
            concurrency: .parallel
        )
        return AnyAgentTool(
            descriptor: tool,
            preflight: { invocation in
                let arguments = try Arguments(invocation)
                let url = try arguments.string("url")
                _ = try RestrictedHTTPHeaderValidator.validate(arguments.requestHeaders())
                guard try await fetcher.classification(for: url) == .restricted else {
                    return AgentToolPreflight(invocation: invocation, safety: .locallyReadOnly)
                }
                guard let parsedURL = URL(string: url) else { throw RestrictedFetchError.invalidURL }
                let origin = try PublicAddressValidator.origin(of: parsedURL)
                return AgentToolPreflight(
                    invocation: invocation,
                    safety: .requiresAuthorization,
                    reasons: ["The fetch target is on a private or otherwise non-public network: \(url)"],
                    executionMetadata: ["authorized_fetch_origins": .array([.string(origin)])]
                )
            },
            execute: { invocation, context in
                let arguments = try Arguments(invocation)
                let headers = try arguments.requestHeaders()
                let authorizedOrigins = Set(
                    context.preflightMetadata["authorized_fetch_origins"]?.arrayValue?
                        .compactMap(\.stringValue) ?? []
                )
                let response = try await fetcher.fetch(
                    try arguments.string("url"),
                    method: arguments.optionalString("method") ?? "GET",
                    headers: headers,
                    authorizedRestrictedOrigins: authorizedOrigins,
                    authorizeRestrictedOrigin: { url, _ in
                        var escalation = tool
                        escalation.safety = .requiresAuthorization
                        var reasons = [
                            "The fetch redirect enters a private or otherwise non-public network: "
                                + url.absoluteString
                        ]
                        if !headers.isEmpty {
                            reasons.append(
                                "Custom headers follow this redirect, including across origins, "
                                    + "matching curl -H -L behavior."
                            )
                        }
                        let request = AgentApprovalRequest(
                            invocation: invocation,
                            descriptor: escalation,
                            userIntent: context.userIntent,
                            localReasons: reasons
                        )
                        switch await context.authorize(request) {
                        case .allow: return
                        case .deny(let reason): throw RestrictedFetchError.authorizationDenied(reason)
                        }
                    }
                )
                return result(invocation, .object([
                    "url": .string(response.url.absoluteString),
                    "status": .number(Double(response.status)),
                    "headers": .object(response.headers.mapValues(AgentJSONValue.string)),
                    "body": .string(response.body), "truncated": .bool(response.truncated),
                ]), truncated: response.truncated)
            }
        )
    }

    /// Finding a URL, as the counterpart to `fetch` reading one.
    ///
    /// Snippets only, deliberately. Every backend here can also return page
    /// text, and taking it would make this a second way to read the web —
    /// one whose destination is chosen by the search engine rather than
    /// classified by us. Leaving it out keeps `fetch` the single door, with its
    /// address classification, redirect budget and private-network escalation
    /// all still on the path.
    ///
    /// `.locallyReadOnly` for a public backend, matching `fetch`: a query is an
    /// outbound request, not a change to anything. It escalates for the same
    /// destinations `fetch` escalates for, which is what stops a search backend
    /// configured at a LAN address from being reached without a word.
    static func webSearch(_ search: WebSearchClient) -> AnyAgentTool {
        let tool = descriptor(
            "web_search",
            "Search the public web. Returns titles, URLs and snippets only; use fetch to read a "
                + "result page in full.",
            properties: ["query": string(max: 1_024), "count": integer(min: 1, max: 10)],
            required: ["query"], target: .network, safety: .locallyReadOnly,
            concurrency: .parallel
        )
        return AnyAgentTool(
            descriptor: tool,
            preflight: { invocation in
                _ = try Arguments(invocation).string("query")
                guard try await search.classification() == .restricted else {
                    return AgentToolPreflight(invocation: invocation, safety: .locallyReadOnly)
                }
                return AgentToolPreflight(
                    invocation: invocation,
                    safety: .requiresAuthorization,
                    reasons: [
                        "The configured search backend is on a private or otherwise non-public "
                            + "network: \(search.resolvedURL)"
                    ]
                )
            },
            execute: { invocation, _ in
                let arguments = try Arguments(invocation)
                let rows = try await search.search(
                    arguments.string("query"), count: arguments.optionalInt("count") ?? 5
                )
                return result(invocation, .array(rows.map { row in
                    .object([
                        "title": .string(row.title), "url": .string(row.url),
                        "snippet": .string(row.snippet),
                        "published_at": row.publishedAt.map { .string($0.ISO8601Format()) } ?? .null,
                    ])
                }))
            }
        )
    }

    private static func requestUserInput() -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "request_user_input",
            """
            Ask the user to decide things you cannot decide yourself, and wait for the answers. \
            Use it only when the answer is genuinely theirs: a preference, a tradeoff with no \
            defensible default, or a fact only they hold — which host is production, where a \
            credential lives. If the repository, the request, or an obvious convention already \
            answers it, choose, say which assumption you made, and keep going; a question the \
            user has to stop and think about costs more than a decision you make and flag. Never \
            use it to ask whether to proceed. Ask a whole group of related decisions in one \
            call, up to three, rather than one at a time — a second question raised only after \
            the first is answered was hidden at the moment it would have informed it. One \
            question is still the common case; three is a ceiling, not a target. Give each \
            question 2-4 options with a description saying what it costs rather than restating \
            the label, and put your recommendation on the option itself instead of in its \
            wording. A free-form field is offered alongside them unless you set allow_custom \
            false, so never write an "Other" option yourself. Omit options entirely for a \
            question no menu can answer, such as a URL or a name. A question may come back with \
            a null answer: that is the user declining to decide that one, not an error and not \
            a reason to ask again — decide it yourself and say which assumption you used.
            """,
            properties: [
                "questions": array(
                    items: object(
                        properties: [
                            "id": string(max: 64),
                            "header": string(max: 24),
                            "prompt": string(max: 4_096),
                            "options": array(
                                items: object(
                                    properties: [
                                        "id": string(max: 64),
                                        "label": string(max: 120),
                                        "description": string(max: 400),
                                        "recommended": boolean(),
                                    ],
                                    required: ["id", "label"]
                                ),
                                max: 4
                            ),
                            "multi_select": boolean(),
                            "allow_custom": boolean(),
                            "custom_placeholder": string(max: 120),
                        ],
                        required: ["id", "prompt"]
                    ),
                    max: AgentUserInputLimits.maxQuestions
                )
            ], required: ["questions"], target: .user, safety: .locallyReadOnly
        )) { invocation, context in
            let questions = try Arguments(invocation).userQuestions()
            let response = await context.userInteraction.request(
                AgentUserInputRequest(questions: questions)
            )
            guard case .answered(let answers) = response else { throw AgentToolError.cancelled }
            return result(invocation, .object([
                "answers": .array(reported(questions, answers))
            ]))
        }
    }

    /// Every question, answered or not, in the order it was asked.
    ///
    /// Reporting the skipped ones rather than omitting them is what makes a
    /// null legible: a model reading its own list back finds each entry where
    /// it put it, and an absent key would read as a bug rather than as the user
    /// declining that one.
    ///
    /// Not private, because this shape *is* the contract with the model and a
    /// test should be able to hold it still.
    static func reported(
        _ questions: [AgentUserQuestion], _ answers: [AgentUserInputAnswer]
    ) -> [AgentJSONValue] {
        let byID = Dictionary(answers.map { ($0.questionID, $0.value) }) { first, _ in first }
        return questions.map { question in
            switch byID[question.id] {
            case .choice(let selectedIDs, let custom):
                let labels = selectedIDs.compactMap { id in
                    question.options.first { $0.id == id }?.label
                }
                return row(
                    question.id,
                    // The canonical human answer, whichever route produced it,
                    // so a model that reads one field reads the right one.
                    answer: custom ?? labels.joined(separator: ", "),
                    selected: selectedIDs, custom: custom
                )
            case .text(let typed):
                return row(question.id, answer: typed, selected: [], custom: typed)
            case .secret:
                // Unreachable — `request_user_input` never builds a secret
                // question. Reported as skipped rather than echoed, so that if
                // one ever does arrive here the plaintext still does not reach
                // the model.
                return row(question.id, answer: nil, selected: [], custom: nil)
            case nil:
                return row(question.id, answer: nil, selected: [], custom: nil)
            }
        }
    }

    private static func row(
        _ questionID: String, answer: String?, selected: [String], custom: String?
    ) -> AgentJSONValue {
        .object([
            "question_id": .string(questionID),
            "answer": answer.map(AgentJSONValue.string) ?? .null,
            "selected_option_ids": .array(selected.map(AgentJSONValue.string)),
            "custom_text": custom.map(AgentJSONValue.string) ?? .null,
        ])
    }

    private static func requestUserSecret() -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "request_user_secret", "Collect a secret in SecureField and return a one-shot bound handle.",
            properties: [
                "prompt": string(max: 4_096), "host_id": string(),
                "consumer_tool": enumeration(["ssh_exec"]), "purpose": string(max: 256),
            ], required: ["prompt", "host_id", "consumer_tool", "purpose"],
            // Sequential, by the default, and it should stay that way despite
            // being read-only: this and `request_user_input` are the two tools
            // whose work is done by a person. Racing them against other calls
            // means output arriving under a question that is still being read.
            target: .user, safety: .locallyReadOnly
        )) { invocation, context in
            let arguments = try Arguments(invocation)
            let hostID = try arguments.uuid("host_id")
            let toolName = try arguments.string("consumer_tool")
            let purpose = try arguments.string("purpose")
            // One question, always. A secret is not a decision among options and
            // has no business sharing a form with one.
            let request = AgentUserInputRequest(
                questions: [
                    AgentUserQuestion(
                        id: "secret", prompt: try arguments.string("prompt"), kind: .secret
                    )
                ],
                purpose: purpose, hostID: hostID
            )
            switch await context.userInteraction.request(request) {
            case .answered(let answers):
                guard case .secret(let secret)? = answers.first?.value else {
                    // A secret must come back through `SecureField` and the
                    // broker. Anything else means it took the ordinary-answer
                    // path, where it would have been echoed on screen and kept
                    // in plain state.
                    throw AgentToolError.invalidArguments(
                        "The secret prompt returned ordinary text."
                    )
                }
                let handle = await context.secretBroker.issue(
                    secret,
                    binding: SecretBinding(
                        runID: context.runID, toolName: toolName, hostID: hostID, purpose: purpose
                    )
                )
                return result(invocation, .object([
                    "secret_handle": .string(handle.id.uuidString), "single_use": .bool(true),
                ]))
            case .cancelled: throw AgentToolError.cancelled
            }
        }
    }

    private typealias SFTPReadOperation = @Sendable (
        any SFTPClientProtocol, String, AgentToolInvocation
    ) async throws -> AgentToolResult

    private static func readOnlySFTP(
        _ name: String, _ summary: String, pool: AgentConnectionPool,
        operation: @escaping SFTPReadOperation
    ) -> AnyAgentTool {
        let tool = descriptor(
            name, summary, properties: ["host_id": string(), "path": string(max: 4_096)],
            required: ["host_id", "path"], target: .host, safety: .locallyReadOnly,
            // Reads only. Two of them cannot disagree about what they saw
            // unless something else is writing, and a writer in the same turn
            // makes the whole turn serial.
            concurrency: .parallel
        )
        return AnyAgentTool(
            descriptor: tool,
            preflight: hostPathPreflight(safety: .locallyReadOnly),
            execute: { invocation, _ in
                let arguments = try Arguments(invocation)
                let client = try await pool.sftp(hostID: arguments.uuid("host_id"))
                return try await operation(client, normalizeRemotePath(arguments.string("path")), invocation)
            }
        )
    }

    private typealias SFTPWriteOperation = @Sendable (
        any SFTPClientProtocol, String, Arguments, AgentToolInvocation
    ) async throws -> AgentToolResult

    private static func writeSFTP(
        _ name: String, _ summary: String, pool: AgentConnectionPool,
        extra: [String: AgentJSONValue] = [:], extraRequired: [String] = [],
        operation: @escaping SFTPWriteOperation
    ) -> AnyAgentTool {
        var properties: [String: AgentJSONValue] = ["host_id": string(), "path": string(max: 4_096)]
        properties.merge(extra) { _, new in new }
        let tool = descriptor(
            name, summary, properties: properties,
            required: ["host_id", "path"] + extraRequired,
            target: .host, safety: .requiresAuthorization
        )
        return AnyAgentTool(
            descriptor: tool,
            preflight: hostPathPreflight(safety: .requiresAuthorization),
            execute: { invocation, _ in
                let arguments = try Arguments(invocation)
                let client = try await pool.sftp(hostID: arguments.uuid("host_id"))
                return try await operation(client, normalizeRemotePath(arguments.string("path")), arguments, invocation)
            }
        )
    }

    /// Resolves `host_id` before approval so the tool card names the host the
    /// action is aimed at rather than an opaque argument blob.
    private static func hostPreflight(
        safety: AgentToolDescriptor.Safety
    ) -> @Sendable (AgentToolInvocation) async throws -> AgentToolPreflight {
        { invocation in
            var checked = invocation
            checked.targetHostID = try Arguments(invocation).uuid("host_id")
            return AgentToolPreflight(invocation: checked, safety: safety)
        }
    }

    private static func hostPathPreflight(
        safety: AgentToolDescriptor.Safety
    ) -> @Sendable (AgentToolInvocation) async throws -> AgentToolPreflight {
        { invocation in
            _ = try normalizeRemotePath(Arguments(invocation).string("path"))
            return try await hostPreflight(safety: safety)(invocation)
        }
    }

    /// Internal rather than private because `scratch_pull` and `scratch_push` aim at
    /// the same remote paths the SFTP tools do, and two implementations of "what is
    /// a valid remote path" would be one too many.
    static func normalizeRemotePath(_ raw: String) throws -> String {
        guard raw.hasPrefix("/"), !raw.contains("\0"), !raw.contains("\r"), !raw.contains("\n") else {
            throw AgentToolError.invalidPath
        }
        var components: [Substring] = []
        for component in raw.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { throw AgentToolError.invalidPath }
                components.removeLast()
            } else { components.append(component) }
        }
        return "/" + components.joined(separator: "/")
    }

    private static func remoteFileJSON(_ file: RemoteFile) -> AgentJSONValue {
        .object([
            "path": .string(file.path), "name": .string(file.name),
            "kind": .string(file.kind.rawValue), "size": .number(Double(file.size)),
            "permissions": .string(file.octalPermissionDescription),
            "modified_at": file.modifiedAt.map { .string($0.ISO8601Format()) } ?? .null,
        ])
    }

}

nonisolated struct Arguments: Sendable {
    let object: [String: AgentJSONValue]

    init(_ invocation: AgentToolInvocation) throws {
        guard let object = invocation.call.arguments.objectValue else {
            throw AgentToolError.invalidArguments("Arguments must be an object.")
        }
        self.object = object
    }

    func string(_ key: String) throws -> String {
        guard let value = object[key]?.stringValue, !value.isEmpty else {
            throw AgentToolError.invalidArguments("\(key) is required.")
        }
        return value
    }

    func uuid(_ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try string(key)) else { throw AgentToolError.invalidHost }
        return value
    }

    func optionalString(_ key: String) -> String? { object[key]?.stringValue }
    func optionalInt(_ key: String) -> Int? { object[key]?.integerValue }
    func optionalBool(_ key: String) -> Bool? { object[key]?.boolValue }
    func optionalStrings(_ key: String) -> [String] {
        object[key]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// The `questions` array of `request_user_input`.
    ///
    /// Everything malformed is rejected rather than dropped. A form silently
    /// missing the question — or the option — the user needed is a worse
    /// failure than an error the model can see and retry.
    func userQuestions() throws -> [AgentUserQuestion] {
        guard let rows = object["questions"]?.arrayValue else {
            throw AgentToolError.invalidArguments("questions must be an array.")
        }
        guard !rows.isEmpty else {
            throw AgentToolError.invalidArguments("questions must contain at least one question.")
        }
        guard rows.count <= AgentUserInputLimits.maxQuestions else {
            throw AgentToolError.invalidArguments(
                "At most \(AgentUserInputLimits.maxQuestions) questions may be asked at once."
            )
        }

        var seen: Set<String> = []
        return try rows.map { row in
            guard let fields = row.objectValue,
                let id = fields["id"]?.stringValue, !id.isEmpty,
                let prompt = fields["prompt"]?.stringValue, !prompt.isEmpty
            else {
                throw AgentToolError.invalidArguments("Each question requires id and prompt.")
            }
            guard seen.insert(id).inserted else {
                throw AgentToolError.invalidArguments("Question ids must be unique: \(id).")
            }

            let options = try Self.options(in: fields)
            return AgentUserQuestion(
                id: id,
                header: fields["header"]?.stringValue ?? "",
                prompt: prompt,
                kind: options.isEmpty
                    ? .text
                    : .choice(
                        AgentUserInputChoice(
                            options: options,
                            allowsCustomAnswer: fields["allow_custom"]?.boolValue ?? true,
                            allowsMultipleAnswers: fields["multi_select"]?.boolValue ?? false,
                            customPlaceholder: fields["custom_placeholder"]?.stringValue ?? ""
                        )
                    )
            )
        }
    }

    private static func options(in question: [String: AgentJSONValue]) throws
        -> [AgentUserInputOption]
    {
        guard let value = question["options"], value != .null else { return [] }
        guard let rows = value.arrayValue else {
            throw AgentToolError.invalidArguments("options must be an array.")
        }
        var seen: Set<String> = []
        return try rows.map { row in
            guard let fields = row.objectValue,
                let id = fields["id"]?.stringValue, !id.isEmpty,
                let label = fields["label"]?.stringValue, !label.isEmpty
            else {
                throw AgentToolError.invalidArguments("Each option requires id and label.")
            }
            guard seen.insert(id).inserted else {
                throw AgentToolError.invalidArguments("Option ids must be unique: \(id).")
            }
            return AgentUserInputOption(
                id: id, label: label,
                detail: fields["description"]?.stringValue ?? "",
                isRecommended: fields["recommended"]?.boolValue ?? false
            )
        }
    }

    func requestHeaders() throws -> [RestrictedHTTPHeader] {
        guard let value = object["headers"], value != .null else { return [] }
        guard let rows = value.arrayValue else {
            throw AgentToolError.invalidArguments("headers must be an array.")
        }
        return try rows.map { row in
            guard let fields = row.objectValue,
                let name = fields["name"]?.stringValue,
                let value = fields["value"]?.stringValue
            else { throw AgentToolError.invalidArguments("Each header requires name and value.") }
            return RestrictedHTTPHeader(name: name, value: value)
        }
    }

    /// `new_text` may legitimately be empty — that is how a block is deleted — so it
    /// is read for presence rather than through `string(_:)`, which rejects empty.
    func scratchEdits() throws -> [ScratchEdit] {
        guard let rows = object["edits"]?.arrayValue, !rows.isEmpty else {
            throw AgentToolError.invalidArguments("edits must be a non-empty array.")
        }
        return try rows.map { row in
            guard let fields = row.objectValue,
                let oldText = fields["old_text"]?.stringValue,
                let newText = fields["new_text"]?.stringValue
            else {
                throw AgentToolError.invalidArguments("Each edit requires old_text and new_text.")
            }
            return ScratchEdit(oldText: oldText, newText: newText)
        }
    }
}

nonisolated enum AgentToolError: LocalizedError, Sendable {
    case invalidHost, invalidPath, notFound, cancelled, invalidArguments(String)
    case scratchPathEscapes
    case scratchNotFound(String)
    case scratchNotText(String)
    case scratchQuotaExceeded(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost: "The host ID is invalid or unavailable."
        case .invalidPath: "The remote path must be an absolute normalized path."
        case .notFound: "The remote path does not exist."
        case .cancelled: "The user cancelled the request."
        case .invalidArguments(let message): message
        case .scratchPathEscapes:
            """
            A scratch path must be relative, must not contain "..", and must stay inside \
            the workspace.
            """
        case .scratchNotFound(let path): "\(path) is not in the scratch workspace."
        case .scratchNotText(let path):
            """
            \(path) is not UTF-8 text. It can still be moved with scratch_push, \
            which does not decode it.
            """
        case .scratchQuotaExceeded(let message): message
        }
    }
}
