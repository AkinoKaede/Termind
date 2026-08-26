import Foundation

nonisolated extension AgentBuiltInTools {
    static func sftpList(
        _ authentication: AgentSSHAuthenticationRegistry, _ pool: AgentConnectionPool
    ) -> AnyAgentTool {
        readOnlySFTP(
            "sftp_list", "List a remote directory.",
            authentication: authentication, pool: pool
        ) {
            client, path, invocation in
            let files = try await client.listDirectory(at: path)
            return result(invocation, .array(files.map(remoteFileJSON)))
        }
    }

    static func sftpStat(
        _ authentication: AgentSSHAuthenticationRegistry, _ pool: AgentConnectionPool
    ) -> AnyAgentTool {
        readOnlySFTP(
            "sftp_stat", "Read remote file metadata.",
            authentication: authentication, pool: pool
        ) {
            client, path, invocation in
            guard let file = try await client.attributes(at: path) else {
                throw AgentToolError.notFound
            }
            return result(invocation, remoteFileJSON(file))
        }
    }

    static func sftpRead(
        _ authentication: AgentSSHAuthenticationRegistry, _ pool: AgentConnectionPool
    ) -> AnyAgentTool {
        readOnlySFTP(
            "sftp_read", "Read a bounded UTF-8 remote file inline.",
            authentication: authentication, pool: pool
        ) {
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

    static func sftpWrite(
        _ authentication: AgentSSHAuthenticationRegistry, _ pool: AgentConnectionPool
    ) -> AnyAgentTool {
        writeSFTP(
            "sftp_write", "Write a bounded UTF-8 remote file atomically.",
            authentication: authentication, pool: pool,
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

    static func sftpMkdir(
        _ authentication: AgentSSHAuthenticationRegistry, _ pool: AgentConnectionPool
    ) -> AnyAgentTool {
        writeSFTP(
            "sftp_mkdir", "Create a remote directory.",
            authentication: authentication, pool: pool
        ) {
            client, path, _, invocation in
            try await client.createDirectory(at: path)
            return result(invocation, .object(["path": .string(path), "created": .bool(true)]))
        }
    }

    static func sftpMove(
        _ authentication: AgentSSHAuthenticationRegistry, _ pool: AgentConnectionPool
    ) -> AnyAgentTool {
        writeSFTP(
            "sftp_move", "Move or rename a remote path.",
            authentication: authentication, pool: pool,
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

    static func sftpChmod(
        _ authentication: AgentSSHAuthenticationRegistry, _ pool: AgentConnectionPool
    ) -> AnyAgentTool {
        writeSFTP(
            "sftp_chmod", "Change remote POSIX permissions.",
            authentication: authentication, pool: pool,
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

    static func sftpDelete(
        _ authentication: AgentSSHAuthenticationRegistry, _ pool: AgentConnectionPool
    ) -> AnyAgentTool {
        writeSFTP(
            "sftp_delete", "Permanently delete one remote file or empty directory.",
            authentication: authentication, pool: pool,
            extra: ["kind": enumeration(["file", "directory"])], extraRequired: ["kind"]
        ) { client, path, arguments, invocation in
            if try arguments.string("kind") == "directory" {
                try await client.removeDirectory(at: path)
            } else { try await client.removeFile(at: path) }
            return result(invocation, .object(["path": .string(path), "deleted": .bool(true)]))
        }
    }

    private typealias SFTPReadOperation = @Sendable (
        any SFTPClientProtocol, String, AgentToolInvocation
    ) async throws -> AgentToolResult

    private static func readOnlySFTP(
        _ name: String, _ summary: String,
        authentication: AgentSSHAuthenticationRegistry, pool: AgentConnectionPool,
        operation: @escaping SFTPReadOperation
    ) -> AnyAgentTool {
        let tool = descriptor(
            name, summary, properties: ["host_id": string(), "path": string(max: 4_096)],
            required: ["host_id", "path"], target: .host, safety: .locallyReadOnly,
            // Reads only. Two of them cannot disagree about what they saw
            // unless something else is writing, and a writer in the same turn
            // makes the whole turn serial.
            concurrency: .parallel, presentation: sftpPresentation(name, summary: summary)
        )
        return AnyAgentTool(
            descriptor: tool,
            preflight: hostPathPreflight(safety: .locallyReadOnly),
            execute: { invocation, context in
                let arguments = try Arguments(invocation)
                let hostID = try arguments.uuid("host_id")
                let path = try normalizeRemotePath(arguments.string("path"))
                return try await withAuthenticatedSFTP(
                    hostID: hostID, invocation: invocation, context: context,
                    authentication: authentication, pool: pool
                ) { client in
                    try await operation(client, path, invocation)
                }
            }
        )
    }

    private typealias SFTPWriteOperation = @Sendable (
        any SFTPClientProtocol, String, Arguments, AgentToolInvocation
    ) async throws -> AgentToolResult

    private static func writeSFTP(
        _ name: String, _ summary: String,
        authentication: AgentSSHAuthenticationRegistry, pool: AgentConnectionPool,
        extra: [String: AgentJSONValue] = [:], extraRequired: [String] = [],
        operation: @escaping SFTPWriteOperation
    ) -> AnyAgentTool {
        var properties: [String: AgentJSONValue] = ["host_id": string(), "path": string(max: 4_096)]
        properties.merge(extra) { _, new in new }
        let tool = descriptor(
            name, summary, properties: properties,
            required: ["host_id", "path"] + extraRequired,
            target: .host, safety: .requiresAuthorization,
            presentation: sftpPresentation(name, summary: summary)
        )
        return AnyAgentTool(
            descriptor: tool,
            preflight: hostPathPreflight(safety: .requiresAuthorization),
            execute: { invocation, context in
                let arguments = try Arguments(invocation)
                let hostID = try arguments.uuid("host_id")
                let path = try normalizeRemotePath(arguments.string("path"))
                return try await withAuthenticatedSFTP(
                    hostID: hostID, invocation: invocation, context: context,
                    authentication: authentication, pool: pool
                ) { client in
                    try await operation(client, path, arguments, invocation)
                }
            }
        )
    }

    private static func sftpPresentation(
        _ name: String, summary: String
    ) -> AgentToolDescriptor.Presentation {
        let symbol = switch name {
        case "sftp_list": "folder"
        case "sftp_stat": "info.circle"
        case "sftp_read": "doc.text"
        case "sftp_write": "square.and.pencil"
        case "sftp_mkdir": "folder.badge.plus"
        case "sftp_move": "arrow.right"
        case "sftp_chmod": "lock"
        case "sftp_delete": "trash"
        default: "externaldrive.connected.to.line.below"
        }
        let action: AgentToolDescriptor.Presentation.Action = switch name {
        case "sftp_list": .init(infinitive: "list", progressive: "Listing", past: "Listed")
        case "sftp_stat": .init(infinitive: "inspect", progressive: "Inspecting", past: "Inspected")
        case "sftp_read": .init(infinitive: "read", progressive: "Reading", past: "Read")
        case "sftp_write": .init(infinitive: "write", progressive: "Writing", past: "Wrote")
        case "sftp_mkdir": .init(infinitive: "create", progressive: "Creating", past: "Created")
        case "sftp_move": .init(infinitive: "move", progressive: "Moving", past: "Moved")
        case "sftp_chmod": .init(
            infinitive: "change permissions for", progressive: "Changing permissions for",
            past: "Changed permissions for"
        )
        case "sftp_delete": .init(infinitive: "delete", progressive: "Deleting", past: "Deleted")
        default: .init(infinitive: "use", progressive: "Using", past: "Used")
        }
        return .init(
            symbol: symbol, activity: .argument(key: "path", fallback: summary), output: .automatic,
            action: action, includesTarget: true
        )
    }

    /// One authenticated SFTP operation. Connection setup may safely retry
    /// after a rejected credential because the operation has not begun. Once
    /// the client is handed to `operation`, a lost connection is only evicted:
    /// replaying a move, delete or write would have unknowable side effects.
    static func withAuthenticatedSFTP<Value: Sendable>(
        hostID: Host.ID, invocation: AgentToolInvocation,
        context: AgentToolExecutionContext,
        authentication: AgentSSHAuthenticationRegistry, pool: AgentConnectionPool,
        operation: @escaping @Sendable (any SFTPClientProtocol) async throws -> Value
    ) async throws -> Value {
        let client = try await authentication.sftp(
            hostID: hostID, invocationID: invocation.id,
            interaction: context.userInteraction, pool: pool
        )
        do {
            return try await operation(client)
        } catch let error as SFTPError {
            switch error {
            case .notConnected, .connectionLost:
                await pool.disconnect(hostID: hostID, kind: .sftp)
            case .cancelled, .localFile, .operation:
                break
            }
            throw error
        }
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

