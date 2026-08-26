import Foundation

nonisolated struct AgentHostTarget: Identifiable, Hashable, Sendable, Codable {
    var id: UUID
    var displayName: String
    var address: String
    var tags: [String]
    var connectionState: String
    var isTemporary: Bool
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

    func targets() -> [AgentHostTarget] {
        let saved = store.hosts.map { host in
            AgentHostTarget(
                id: host.id, displayName: host.name, address: store.loginAddress(for: host),
                tags: host.tags, connectionState: Self.stateName(store.status(of: host.id)),
                isTemporary: false
            )
        }
        return saved + temporaryTargets()
    }

    func configuration(for id: UUID) throws -> SSHConnectionConfiguration {
        if let host = store.host(id) { return try store.sshConnectionConfiguration(for: host) }
        if let configuration = try temporaryConfiguration(id) { return configuration }
        throw AgentToolError.invalidHost
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
        timeout: TimeInterval, outputLimit: Int, hostID: UUID
    ) async throws -> SSHExecResult {
        do {
            return try await exec(hostID: hostID).execute(
                command, workingDirectory: workingDirectory, stdin: stdin,
                timeout: timeout, outputLimit: outputLimit
            )
        } catch SSHExecSessionError.channelUnavailable {
            await disconnect(hostID: hostID, kind: .exec)
            return try await exec(hostID: hostID).execute(
                command, workingDirectory: workingDirectory, stdin: stdin,
                timeout: timeout, outputLimit: outputLimit
            )
        }
    }

    func exec(hostID: UUID) async throws -> any SSHExecSessionProtocol {
        guard case .exec(let session) = try await resolve(hostID: hostID, kind: .exec)
        else { throw AgentToolError.invalidHost }
        return session
    }

    func sftp(hostID: UUID) async throws -> any SFTPClientProtocol {
        guard case .sftp(let client) = try await resolve(hostID: hostID, kind: .sftp)
        else { throw AgentToolError.invalidHost }
        return client
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

    private func resolve(hostID: UUID, kind: Kind) async throws -> Client {
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
                return try await open(key: key, fingerprint: fingerprint)
            }
            entries[key] = Entry(
                client: entry.client, fingerprint: fingerprint, lastUsedAt: .now
            )
            return entry.client
        }
        return try await open(key: key, fingerprint: fingerprint)
    }

    private func open(key: Key, fingerprint: String) async throws -> Client {
        // Without this join, two tool calls that both miss the cache would each
        // build a connection and one of them would never be pooled — or closed.
        if let inFlight = pending[key], inFlight.fingerprint == fingerprint {
            let client = try await inFlight.task.value
            commit(client, key: key, fingerprint: fingerprint)
            return client
        }
        let task = Task { [configuration, openExec, openSFTP] () async throws -> Client in
            let resolved = try await configuration(key.hostID)
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
        commit(client, key: key, fingerprint: fingerprint)
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

nonisolated enum AgentBuiltInTools {
    /// `search` is optional, and nil means the tool is not registered at all
    /// rather than registered and always failing. A model shown a `web_search`
    /// it cannot use spends a turn discovering that; a model not shown one
    /// reaches for `fetch` or asks, which is the behaviour we want when no
    /// backend is configured. It is also nil whenever the model has provider
    /// search of its own — see `AppModel.webSearchPlan`.
    static func make(
        hosts: AgentHostResolver,
        connections: AgentConnectionPool,
        fetcher: RestrictedHTTPFetcher = RestrictedHTTPFetcher(),
        search: WebSearchClient? = nil
    ) -> [AnyAgentTool] {
        [
            listHosts(hosts), sshExec(connections), terminalSuggest(),
            sftpList(connections), sftpStat(connections), sftpRead(connections),
            sftpWrite(connections), sftpMkdir(connections), sftpMove(connections),
            sftpChmod(connections), sftpDelete(connections), fetch(fetcher),
            requestUserInput(), requestUserSecret(),
        ] + (search.map { [webSearch($0)] } ?? [])
    }

    private static func listHosts(_ hosts: AgentHostResolver) -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "list_hosts", "List Vault and temporary Termind SSH targets without credentials.",
            properties: [:], required: [], target: .host, safety: .locallyReadOnly
        )) { invocation, _ in
            let rows = await hosts.targets().map { target in
                AgentJSONValue.object([
                    "id": .string(target.id.uuidString), "display_name": .string(target.displayName),
                    "address": .string(target.address), "tags": .array(target.tags.map(AgentJSONValue.string)),
                    "connection_state": .string(target.connectionState),
                    "temporary": .bool(target.isTemporary),
                ])
            }
            return result(invocation, .array(rows))
        }
    }

    private static func sshExec(_ pool: AgentConnectionPool) -> AnyAgentTool {
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
                return AgentToolPreflight(
                    invocation: checked,
                    safety: assessment.risk == .safe ? .locallyReadOnly : .requiresAuthorization,
                    reasons: assessment.reasons
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
                let output = try await pool.execute(
                    command, workingDirectory: arguments.optionalString("cwd"), stdin: input,
                    timeout: TimeInterval(arguments.optionalInt("timeout_seconds") ?? 60),
                    outputLimit: 256 * 1_024, hostID: hostID
                )
                return result(invocation, .object([
                    "stdout": .string(output.stdout), "stderr": .string(output.stderr),
                    "exit_code": .number(Double(output.exitCode)),
                    "signal": output.signal.map(AgentJSONValue.string) ?? .null,
                    "stdout_truncated": .bool(output.stdoutTruncated),
                    "stderr_truncated": .bool(output.stderrTruncated),
                ]), truncated: output.stdoutTruncated || output.stderrTruncated)
            }
        )
    }

    private static func terminalSuggest() -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "terminal_suggest", "Create a command card. Only the user can insert or run it in a PTY.",
            properties: ["command": string(max: 32_768), "explanation": string(max: 4_096)],
            required: ["command"], target: .user, safety: .locallyReadOnly
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
            required: ["url"], target: .network, safety: .locallyReadOnly
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
            required: ["query"], target: .network, safety: .locallyReadOnly
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
            Ask the user to decide something you cannot decide yourself, and wait for the answer. \
            Use it only when the answer is genuinely theirs: a preference, a tradeoff with no \
            defensible default, or a fact only they hold — which host is production, where a \
            credential lives. If the repository, the request, or an obvious convention already \
            answers it, choose, say which assumption you made, and keep going; a question the \
            user has to stop and think about costs more than a decision you make and flag. Never \
            use it to ask whether to proceed. Give 2-4 options, each with a description saying \
            what it costs rather than restating the label, and put your recommendation on the \
            option itself instead of in its wording. A free-form field is offered alongside them \
            unless you set allow_custom false, so never write an "Other" option yourself. Omit \
            options entirely for a question no menu can answer, such as a URL or a name.
            """,
            properties: [
                "prompt": string(max: 4_096),
                "header": string(max: 24),
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
            ], required: ["prompt"], target: .user, safety: .locallyReadOnly
        )) { invocation, context in
            let arguments = try Arguments(invocation)
            let options = try arguments.userInputOptions()
            let request = AgentUserInputRequest(
                prompt: try arguments.string("prompt"),
                kind: options.isEmpty
                    ? .text
                    : .choice(
                        AgentUserInputChoice(
                            options: options,
                            allowsCustomAnswer: arguments.optionalBool("allow_custom") ?? true,
                            allowsMultipleAnswers: arguments.optionalBool("multi_select") ?? false,
                            customPlaceholder: arguments.optionalString("custom_placeholder") ?? ""
                        )
                    ),
                header: arguments.optionalString("header") ?? ""
            )
            switch await context.userInteraction.request(request) {
            case .text(let answer):
                return result(invocation, .object(["answer": .string(answer)]))
            case .choice(let selectedIDs, let custom):
                let labels = selectedIDs.compactMap { id in
                    options.first { $0.id == id }?.label
                }
                return result(invocation, .object([
                    // The canonical human answer, whichever route produced it,
                    // so a model that reads only one field still reads the
                    // right one.
                    "answer": .string(custom ?? labels.joined(separator: ", ")),
                    "selected_option_ids": .array(selectedIDs.map(AgentJSONValue.string)),
                    "custom_text": custom.map(AgentJSONValue.string) ?? .null,
                ]))
            case .secret:
                throw AgentToolError.invalidArguments("Secret input must use request_user_secret.")
            case .cancelled:
                throw AgentToolError.cancelled
            }
        }
    }

    private static func requestUserSecret() -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "request_user_secret", "Collect a secret in SecureField and return a one-shot bound handle.",
            properties: [
                "prompt": string(max: 4_096), "host_id": string(),
                "consumer_tool": enumeration(["ssh_exec"]), "purpose": string(max: 256),
            ], required: ["prompt", "host_id", "consumer_tool", "purpose"],
            target: .user, safety: .locallyReadOnly
        )) { invocation, context in
            let arguments = try Arguments(invocation)
            let hostID = try arguments.uuid("host_id")
            let toolName = try arguments.string("consumer_tool")
            let purpose = try arguments.string("purpose")
            let request = AgentUserInputRequest(
                prompt: try arguments.string("prompt"), kind: .secret,
                purpose: purpose, hostID: hostID
            )
            switch await context.userInteraction.request(request) {
            case .secret(let secret):
                let handle = await context.secretBroker.issue(
                    secret,
                    binding: SecretBinding(
                        runID: context.runID, toolName: toolName, hostID: hostID, purpose: purpose
                    )
                )
                return result(invocation, .object([
                    "secret_handle": .string(handle.id.uuidString), "single_use": .bool(true),
                ]))
            case .text, .choice:
                // A secret must come back through `SecureField` and the broker.
                // Anything else means it took the ordinary-answer path, where it
                // would have been echoed on screen and kept in plain state.
                throw AgentToolError.invalidArguments("The secret prompt returned ordinary text.")
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
            required: ["host_id", "path"], target: .host, safety: .locallyReadOnly
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

    private static func normalizeRemotePath(_ raw: String) throws -> String {
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

    private static func result(
        _ invocation: AgentToolInvocation, _ value: AgentJSONValue, truncated: Bool = false
    ) -> AgentToolResult {
        AgentToolResult(
            callID: invocation.call.id,
            content: "<untrusted-data>\n\(value.encodedString)\n</untrusted-data>",
            isTruncated: truncated,
            metadata: ["untrusted": .bool(true)]
        )
    }

    private static func descriptor(
        _ name: String, _ summary: String, properties: [String: AgentJSONValue],
        required: [String], target: AgentToolDescriptor.Target,
        safety: AgentToolDescriptor.Safety
    ) -> AgentToolDescriptor {
        AgentToolDescriptor(
            name: name, summary: summary,
            inputSchema: .object([
                "type": .string("object"), "properties": .object(properties),
                "required": .array(required.map(AgentJSONValue.string)),
                "additionalProperties": .bool(false),
            ]),
            target: target, safety: safety
        )
    }

    private static func string(max: Int? = nil) -> AgentJSONValue {
        var schema: [String: AgentJSONValue] = ["type": .string("string")]
        if let max { schema["maxLength"] = .number(Double(max)) }
        return .object(schema)
    }

    private static func boolean() -> AgentJSONValue { .object(["type": .string("boolean")]) }

    private static func integer(min: Int, max: Int) -> AgentJSONValue {
        .object([
            "type": .string("integer"), "minimum": .number(Double(min)),
            "maximum": .number(Double(max)),
        ])
    }

    private static func enumeration(_ values: [String]) -> AgentJSONValue {
        .object([
            "type": .string("string"), "enum": .array(values.map(AgentJSONValue.string)),
        ])
    }

    private static func array(items: AgentJSONValue, max: Int) -> AgentJSONValue {
        .object([
            "type": .string("array"), "items": items, "maxItems": .number(Double(max)),
        ])
    }

    private static func object(
        properties: [String: AgentJSONValue], required: [String]
    ) -> AgentJSONValue {
        .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array(required.map(AgentJSONValue.string)),
            "additionalProperties": .bool(false),
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

    /// The `options` array of `request_user_input`.
    ///
    /// Malformed rows are rejected rather than dropped. A menu silently missing
    /// the option the user wanted is a worse failure than an error the model
    /// can see and retry.
    func userInputOptions() throws -> [AgentUserInputOption] {
        guard let value = object["options"], value != .null else { return [] }
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
}

nonisolated enum AgentToolError: LocalizedError, Sendable {
    case invalidHost, invalidPath, notFound, cancelled, invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost: "The host ID is invalid or unavailable."
        case .invalidPath: "The remote path must be an absolute normalized path."
        case .notFound: "The remote path does not exist."
        case .cancelled: "The user cancelled the request."
        case .invalidArguments(let message): message
        }
    }
}
