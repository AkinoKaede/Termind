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
        let actionKind: AgentToolDescriptor.Presentation.ActionKind = switch name {
        case "sftp_list": .list
        case "sftp_stat": .inspect
        case "sftp_read": .read
        case "sftp_write": .write
        case "sftp_mkdir": .create
        case "sftp_move": .move
        case "sftp_chmod": .changePermissions
        case "sftp_delete": .delete
        default: .use
        }
        return .init(
            symbol: symbol, activity: .semanticArgument(key: "path", fallback: .remoteFile),
            output: .automatic, detailPresenterID: "builtin.\(name)",
            actionKind: actionKind, includesTarget: true
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

// MARK: - Tool-owned transcript details

nonisolated extension AgentBuiltInTools {
    static let sftpListDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.sftp_list", present: presentRemoteFileList
    )
    static let sftpStatDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.sftp_stat", present: presentRemoteFileStat
    )
    static let sftpReadDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.sftp_read", present: presentRemoteFileContent
    )
    static let sftpWriteDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.sftp_write", present: presentSFTPWrite
    )
    static let sftpMkdirDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.sftp_mkdir", present: presentSFTPMkdir
    )
    static let sftpMoveDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.sftp_move", present: presentSFTPMove
    )
    static let sftpChmodDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.sftp_chmod", present: presentSFTPChmod
    )
    static let sftpDeleteDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.sftp_delete", present: presentSFTPDelete
    )

    private static func presentRemoteFileList(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let values = input.result.arrayValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
        let rows = values.compactMap { remoteFileDetailRow($0, locale: input.locale) }
        return [
            .message(String(localized: "\(rows.count) items", locale: input.locale), .secondary),
            .list(.init(
                title: nil, rows: rows,
                emptyMessage: F.localized("Directory is empty", locale: input.locale)
            )),
        ]
    }

    private static func remoteFileDetailRow(
        _ value: AgentJSONValue, locale: Locale
    ) -> AgentToolDetail.ListRow? {
        typealias F = AgentToolDetailFormatting
        guard let object = value.objectValue else { return nil }
        let path = object["path"]?.stringValue ?? ""
        let name = F.nonempty(object["name"]?.stringValue)
            ?? F.nonempty(path.split(separator: "/").last.map(String.init))
            ?? F.localized("Unnamed item", locale: locale)
        let kind = object["kind"]?.stringValue ?? ""
        var metadata = [F.kindLabel(kind, locale: locale)]
        if let bytes = object["size"]?.integerValue { metadata.append(F.byteCount(bytes)) }
        if let permissions = F.nonempty(object["permissions"]?.stringValue) {
            metadata.append(permissions)
        }
        return .init(
            title: name, subtitle: metadata.filter { !$0.isEmpty }.joined(separator: " · "),
            detail: object["modified_at"]?.stringValue.map(F.displayDate),
            symbol: kind == "directory" ? "folder" : "doc"
        )
    }

    private static func presentRemoteFileStat(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
        var items: [AgentToolDetail.Item] = []
        F.appendField(&items, "Path", object["path"]?.stringValue, locale: input.locale, monospaced: true)
        F.appendField(
            &items, "Kind", object["kind"]?.stringValue.map {
                F.kindLabel($0, locale: input.locale)
            }, locale: input.locale
        )
        if let bytes = object["size"]?.integerValue {
            items.append(F.field("Size", F.byteCount(bytes), locale: input.locale))
        }
        F.appendField(
            &items, "Permissions", object["permissions"]?.stringValue,
            locale: input.locale, monospaced: true
        )
        F.appendField(
            &items, "Modified", object["modified_at"]?.stringValue.map(F.displayDate),
            locale: input.locale
        )
        return items
    }

    private static func presentRemoteFileContent(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
        var items: [AgentToolDetail.Item] = []
        F.appendField(&items, "Path", object["path"]?.stringValue, locale: input.locale, monospaced: true)
        let content = object["content"]?.stringValue ?? ""
        items.append(content.isEmpty
            ? .message(F.localized("Empty file", locale: input.locale), .secondary)
            : .text(.init(
                title: F.localized("Content", locale: input.locale), text: content,
                style: .monospaced
            )))
        if let bytes = object["bytes"]?.integerValue {
            items.append(F.field("Size", F.byteCount(bytes), locale: input.locale))
        }
        return items
    }

    private static func presentSFTPWrite(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
        var items: [AgentToolDetail.Item] = []
        F.appendField(&items, "Path", object["path"]?.stringValue, locale: input.locale, monospaced: true)
        if let content = input.arguments["content"]?.stringValue {
            items.append(F.field("Size", F.byteCount(content.utf8.count), locale: input.locale))
        }
        items.append(F.field("Result", F.localized("Written", locale: input.locale), locale: input.locale))
        return items
    }

    private static func presentSFTPMkdir(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        pathDetail(input, result: AgentToolDetailFormatting.localized(
            "Directory created", locale: input.locale
        ))
    }

    private static func pathDetail(
        _ input: AgentToolDetailInput, result: String
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
        var items: [AgentToolDetail.Item] = []
        F.appendField(&items, "Path", object["path"]?.stringValue, locale: input.locale, monospaced: true)
        items.append(F.field("Result", result, locale: input.locale))
        return items
    }

    private static func presentSFTPMove(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
        var items: [AgentToolDetail.Item] = []
        F.appendField(&items, "From", object["source"]?.stringValue, locale: input.locale, monospaced: true)
        F.appendField(&items, "To", object["destination"]?.stringValue, locale: input.locale, monospaced: true)
        return items
    }

    private static func presentSFTPChmod(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
        var items: [AgentToolDetail.Item] = []
        F.appendField(&items, "Path", object["path"]?.stringValue, locale: input.locale, monospaced: true)
        F.appendField(&items, "Permissions", object["mode"]?.stringValue, locale: input.locale, monospaced: true)
        return items
    }

    private static func presentSFTPDelete(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
        var items: [AgentToolDetail.Item] = []
        F.appendField(&items, "Path", object["path"]?.stringValue, locale: input.locale, monospaced: true)
        F.appendField(
            &items, "Kind", input.arguments["kind"]?.stringValue.map {
                F.kindLabel($0, locale: input.locale)
            }, locale: input.locale
        )
        items.append(F.field("Result", F.localized("Deleted", locale: input.locale), locale: input.locale))
        return items
    }
}
