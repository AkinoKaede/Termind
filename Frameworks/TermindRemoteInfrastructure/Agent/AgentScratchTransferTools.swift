import AgentKit
import Foundation
import TermindApplication

// The two scratch tools that touch a host.
//
// They live here rather than with the rest of the scratch family because they
// are the only two that leave the workspace: `scratch_pull` opens an SFTP
// client to read a remote file into it, and `scratch_push` writes one back.
// Everything between those two ends — read, search, edit, diff — is the
// runtime's and knows nothing about SSH.
//
// That is also the shape the pair exists for. A remote file can be pulled,
// edited and pushed back without a copy of it crossing the model boundary in
// either direction, and the only step the user is asked to approve is the one
// that reaches their host.

nonisolated public struct ScratchPullTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(id: "builtin.scratch_pull", present: present)
    public let workspace: AgentScratchWorkspace
    public let pool: AgentConnectionPool
    public let authentication: AgentSSHAuthenticationRegistry

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "scratch_pull", "Copy a remote file into the scratch workspace without returning its contents.",
            properties: [
                "host_id": Self.string(), "remote_path": Self.string(max: 4_096),
                "scratch_path": Self.string(max: AgentScratchWorkspace.Limits.pathBytes),
            ], required: ["host_id", "remote_path", "scratch_path"], target: .host,
            approvalPolicy: .approve, concurrency: .parallel,
            presentation: .init(
                symbol: "arrow.down.doc",
                activity: .semanticArgument(key: "remote_path", fallback: .remoteFile),
                output: .json, actionKind: .pull
            )
        )
    }

    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        var checked = invocation
        let arguments = try Arguments(invocation)
        checked.targetHostID = try arguments.uuid("host_id")
        _ = try AgentToolSupport.normalizeRemotePath(arguments.string("remote_path"))
        _ = try AgentScratchWorkspace.normalize(arguments.string("scratch_path"))
        return AgentToolPreflight(invocation: checked, approvalPolicy: .approve)
    }

    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let arguments = try Arguments(invocation)
        let remote = try AgentToolSupport.normalizeRemotePath(arguments.string("remote_path"))
        let hostID = try arguments.uuid("host_id")
        let data = try await AgentToolSupport.withAuthenticatedSFTP(
            hostID: hostID, invocation: invocation, context: context,
            authentication: authentication, pool: pool,
            schedulesDataTransfer: true
        ) { client in
            try await client.readFile(at: remote, maximumBytes: .max)
        }
        let written = try await workspace.write(arguments.string("scratch_path"), data: data)
        let text = String(data: data, encoding: .utf8).map(LineEnding.normalizedToLF)
        return Self.result(
            invocation,
            .object([
                "remote_path": .string(remote), "scratch_path": .string(written.path),
                "bytes": .number(Double(written.bytes)), "sha256": .string(written.sha256),
                "is_utf8": .bool(text != nil),
                "lines": text.map { .number(Double(UnifiedDiff.split($0).lines.count)) } ?? .null,
            ]))
    }

    public init(
        workspace: AgentScratchWorkspace, pool: AgentConnectionPool, authentication: AgentSSHAuthenticationRegistry
    ) {
        self.workspace = workspace
        self.pool = pool
        self.authentication = authentication
    }
}

nonisolated public struct ScratchPushTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.scratch_push", present: present,
        presentArguments: presentArguments
    )
    public let workspace: AgentScratchWorkspace
    public let pool: AgentConnectionPool
    public let authentication: AgentSSHAuthenticationRegistry

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "scratch_push", "Copy a scratch file atomically to a remote path.",
            properties: [
                "host_id": Self.string(),
                "scratch_path": Self.string(max: AgentScratchWorkspace.Limits.pathBytes),
                "remote_path": Self.string(max: 4_096), "overwrite": Self.boolean(),
            ], required: ["host_id", "scratch_path", "remote_path"], target: .host,
            approvalPolicy: .ask,
            presentation: .init(
                symbol: "arrow.up.doc",
                activity: .semanticArgument(key: "remote_path", fallback: .remoteFile),
                output: .json, actionKind: .push
            )
        )
    }

    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        var checked = invocation
        let arguments = try Arguments(invocation)
        checked.targetHostID = try arguments.uuid("host_id")
        _ = try AgentToolSupport.normalizeRemotePath(arguments.string("remote_path"))
        let staged = try arguments.string("scratch_path")
        let file = try await workspace.data(at: staged)
        return AgentToolPreflight(
            invocation: checked, approvalPolicy: .ask,
            reasons: Self.evidence(path: staged, file: file),
            executionMetadata: ["scratch_sha256": .string(file.sha256)]
        )
    }

    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let arguments = try Arguments(invocation)
        let remote = try AgentToolSupport.normalizeRemotePath(arguments.string("remote_path"))
        let staged = try arguments.string("scratch_path")
        let file = try await workspace.data(at: staged)
        if let approved = context.preflightMetadata["scratch_sha256"]?.stringValue,
            approved != file.sha256
        {
            throw AgentToolError.invalidArguments(
                "\(staged) changed after this push was approved. Nothing was written."
            )
        }
        let hostID = try arguments.uuid("host_id")
        try await AgentToolSupport.withAuthenticatedSFTP(
            hostID: hostID, invocation: invocation, context: context,
            authentication: authentication, pool: pool,
            byteCount: Int64(file.bytes), schedulesDataTransfer: true
        ) { client in
            try await client.writeFile(
                file.data, at: remote, overwrite: arguments.optionalBool("overwrite") ?? false
            )
        }
        return Self.result(
            invocation,
            .object([
                "scratch_path": .string(staged), "remote_path": .string(remote),
                "bytes": .number(Double(file.bytes)), "sha256": .string(file.sha256),
                "written": .bool(true),
            ]))
    }

    private static func evidence(path: String, file: ScratchFile) -> [String] {
        var reasons = ["The content comes from the scratch workspace: \(path)"]
        guard let text = String(data: file.data, encoding: .utf8) else {
            reasons.append("\(file.bytes) bytes of non-text data, sha256 \(file.sha256.prefix(16))…")
            return reasons
        }
        let lines = UnifiedDiff.split(LineEnding.normalizedToLF(text)).lines
        reasons.append("\(file.bytes) bytes, \(lines.count) lines, sha256 \(file.sha256.prefix(16))…")
        reasons.append(
            "First lines: "
                + AgentSensitiveDataRedactor.visibleText(
                    lines.prefix(20).joined(separator: "\n"), maximumCharacters: 600
                ))
        return reasons
    }

    public init(
        workspace: AgentScratchWorkspace, pool: AgentConnectionPool, authentication: AgentSSHAuthenticationRegistry
    ) {
        self.workspace = workspace
        self.pool = pool
        self.authentication = authentication
    }
}

nonisolated extension ScratchPullTool {
    public static func present(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            F.appendField(
                &items, "Remote path", object["remote_path"]?.stringValue, locale: input.locale, monospaced: true)
            F.appendField(
                &items, "Scratch path", object["scratch_path"]?.stringValue, locale: input.locale, monospaced: true)
            F.appendBytes(&items, "Size", object["bytes"], locale: input.locale)
            items.append(
                F.field(
                    "Content type",
                    object["is_utf8"]?.boolValue == true
                        ? F.localized("UTF-8 text", locale: input.locale)
                        : F.localized("Binary", locale: input.locale),
                    locale: input.locale
                ))
            if let lines = object["lines"]?.integerValue {
                items.append(F.field("Lines", String(lines), locale: input.locale))
            }
            F.appendField(&items, "SHA-256", object["sha256"]?.stringValue, locale: input.locale, monospaced: true)
            return items
        }
    }
}

nonisolated extension ScratchPushTool {
    public static func present(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            F.appendField(
                &items, "Scratch path", object["scratch_path"]?.stringValue, locale: input.locale, monospaced: true)
            F.appendField(
                &items, "Remote path", object["remote_path"]?.stringValue, locale: input.locale, monospaced: true)
            F.appendBytes(&items, "Size", object["bytes"], locale: input.locale)
            F.appendField(&items, "SHA-256", object["sha256"]?.stringValue, locale: input.locale, monospaced: true)
            items.append(F.field("Result", F.localized("Written", locale: input.locale), locale: input.locale))
            return items
        }
    }

    public static func presentArguments(
        _ input: AgentToolArgumentDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        var items: [AgentToolDetail.Item] = []
        F.appendField(
            &items, "Scratch path", input.arguments["scratch_path"]?.stringValue,
            locale: input.locale, monospaced: true)
        F.appendField(
            &items, "Remote path", input.arguments["remote_path"]?.stringValue,
            locale: input.locale, monospaced: true)
        SFTPToolPresentation.appendBoolean(
            &items, label: "Overwrite", value: input.arguments["overwrite"],
            locale: input.locale)
        return items
    }
}
