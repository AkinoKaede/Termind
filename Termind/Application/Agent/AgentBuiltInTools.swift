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

actor AgentConnectionPool {
    private struct Key: Hashable { var runID: UUID; var hostID: UUID }
    private let hosts: AgentHostResolver
    private let coordinator: RemoteConnectionCoordinator
    private var sftpClients: [Key: any SFTPClientProtocol] = [:]

    init(hosts: AgentHostResolver, coordinator: RemoteConnectionCoordinator) {
        self.hosts = hosts
        self.coordinator = coordinator
    }

    func configuration(for hostID: UUID) async throws -> SSHConnectionConfiguration {
        try await hosts.configuration(for: hostID)
    }

    func sftp(runID: UUID, hostID: UUID) async throws -> any SFTPClientProtocol {
        let key = Key(runID: runID, hostID: hostID)
        if let client = sftpClients[key] { return client }
        let configuration = try await hosts.configuration(for: hostID)
        let client = try await coordinator.connectSFTP(using: configuration)
        sftpClients[key] = client
        return client
    }

    func cleanup(runID: UUID) async {
        let keys = sftpClients.keys.filter { $0.runID == runID }
        let clients = keys.compactMap { sftpClients.removeValue(forKey: $0) }
        for client in clients { await client.disconnect() }
    }
}

nonisolated enum AgentBuiltInTools {
    static func make(
        hosts: AgentHostResolver,
        connections: AgentConnectionPool,
        fetcher: RestrictedHTTPFetcher = RestrictedHTTPFetcher()
    ) -> [AnyAgentTool] {
        [
            listHosts(hosts), sshExec(connections), terminalSuggest(),
            sftpList(connections), sftpStat(connections), sftpRead(connections),
            sftpWrite(connections), sftpMkdir(connections), sftpMove(connections),
            sftpChmod(connections), sftpDelete(connections), fetch(fetcher),
            requestUserInput(), requestUserSecret(),
        ]
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
                let configuration = try await pool.configuration(for: hostID)
                let output = try await SSHSessionActor.execute(
                    command, workingDirectory: arguments.optionalString("cwd"), stdin: input,
                    timeout: TimeInterval(arguments.optionalInt("timeout_seconds") ?? 60),
                    outputLimit: 256 * 1_024, using: configuration
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

    private static func fetch(_ fetcher: RestrictedHTTPFetcher) -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "fetch", "Fetch a bounded public HTTP(S) resource. Private and local networks are blocked.",
            properties: ["url": string(max: 8_192), "method": enumeration(["GET", "HEAD"])],
            required: ["url"], target: .network, safety: .requiresAuthorization
        )) { invocation, _ in
            let arguments = try Arguments(invocation)
            let response = try await fetcher.fetch(
                try arguments.string("url"), method: arguments.optionalString("method") ?? "GET"
            )
            return result(invocation, .object([
                "url": .string(response.url.absoluteString),
                "status": .number(Double(response.status)),
                "headers": .object(response.headers.mapValues(AgentJSONValue.string)),
                "body": .string(response.body), "truncated": .bool(response.truncated),
            ]), truncated: response.truncated)
        }
    }

    private static func requestUserInput() -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "request_user_input", "Pause and ask the user for text or one structured choice.",
            properties: [
                "prompt": string(max: 4_096),
                "choices": array(items: string(max: 256), max: 20),
            ], required: ["prompt"], target: .user, safety: .locallyReadOnly
        )) { invocation, context in
            let arguments = try Arguments(invocation)
            let choices = arguments.optionalStrings("choices")
            let request = AgentUserInputRequest(
                prompt: try arguments.string("prompt"),
                kind: choices.isEmpty ? .text : .choice(choices)
            )
            switch await context.userInteraction.request(request) {
            case .text(let answer): return result(invocation, .object(["answer": .string(answer)]))
            case .secret: throw AgentToolError.invalidArguments("Secret input must use request_user_secret.")
            case .cancelled: throw AgentToolError.cancelled
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
            case .text: throw AgentToolError.invalidArguments("The secret prompt returned ordinary text.")
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
            execute: { invocation, context in
                let arguments = try Arguments(invocation)
                let client = try await pool.sftp(runID: context.runID, hostID: arguments.uuid("host_id"))
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
            execute: { invocation, context in
                let arguments = try Arguments(invocation)
                let client = try await pool.sftp(runID: context.runID, hostID: arguments.uuid("host_id"))
                return try await operation(client, normalizeRemotePath(arguments.string("path")), arguments, invocation)
            }
        )
    }

    private static func hostPathPreflight(
        safety: AgentToolDescriptor.Safety
    ) -> @Sendable (AgentToolInvocation) async throws -> AgentToolPreflight {
        { invocation in
            let arguments = try Arguments(invocation)
            _ = try normalizeRemotePath(arguments.string("path"))
            var checked = invocation
            checked.targetHostID = try arguments.uuid("host_id")
            return AgentToolPreflight(invocation: checked, safety: safety)
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
