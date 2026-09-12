import AgentKit
import Foundation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

nonisolated public protocol SFTPToolDefinition: AgentToolDefinition, AgentToolSchemaBuilding {
    static var name: String { get }
    static var summary: String { get }
    static var safety: AgentToolDescriptor.Safety { get }
    static var concurrency: AgentToolDescriptor.Concurrency { get }
    static var extraProperties: [String: AgentJSONValue] { get }
    static var extraRequired: [String] { get }
    static var presentation: AgentToolDescriptor.Presentation { get }
    var authentication: AgentSSHAuthenticationRegistry { get }
    var connections: AgentConnectionPool { get }
    func perform(
        client: any SFTPClientProtocol, path: String, arguments: Arguments,
        invocation: AgentToolInvocation
    ) async throws -> AgentToolResult
}

nonisolated extension SFTPToolDefinition {
    public static var concurrency: AgentToolDescriptor.Concurrency {
        safety == .locallyReadOnly ? .parallel : .sequential
    }
    public static var extraProperties: [String: AgentJSONValue] { [:] }
    public static var extraRequired: [String] { [] }

    public var descriptor: AgentToolDescriptor {
        var properties: [String: AgentJSONValue] = [
            "host_id": Self.string(), "path": Self.string(max: 4_096),
        ]
        properties.merge(Self.extraProperties) { _, new in new }
        return Self.descriptor(
            Self.name, Self.summary, properties: properties,
            required: ["host_id", "path"] + Self.extraRequired,
            target: .host, safety: Self.safety, concurrency: Self.concurrency,
            presentation: Self.presentation
        )
    }

    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        var checked = invocation
        let arguments = try Arguments(invocation)
        checked.targetHostID = try arguments.uuid("host_id")
        _ = try AgentToolSupport.normalizeRemotePath(arguments.string("path"))
        return AgentToolPreflight(invocation: checked, safety: Self.safety)
    }

    public func execute(
        _ invocation: AgentToolInvocation, context: AgentToolExecutionContext
    ) async throws -> AgentToolResult {
        let arguments = try Arguments(invocation)
        let hostID = try arguments.uuid("host_id")
        let path = try AgentToolSupport.normalizeRemotePath(arguments.string("path"))
        return try await AgentToolSupport.withAuthenticatedSFTP(
            hostID: hostID, invocation: invocation, context: context,
            authentication: authentication, pool: connections
        ) { client in
            try await perform(
                client: client, path: path, arguments: arguments, invocation: invocation
            )
        }
    }
}

nonisolated public struct SFTPListTool: SFTPToolDefinition {
    public static let name = "sftp_list"
    public static let summary = "List a remote directory."
    public static let safety: AgentToolDescriptor.Safety = .locallyReadOnly
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.sftp_list", present: present
    )
    public static let presentation = AgentToolDescriptor.Presentation(
        symbol: "folder", activity: .semanticArgument(key: "path", fallback: .remoteFile),
        output: .automatic, actionKind: .list
    )
    public let authentication: AgentSSHAuthenticationRegistry
    public let connections: AgentConnectionPool
    public func perform(
        client: any SFTPClientProtocol, path: String, arguments: Arguments,
        invocation: AgentToolInvocation
    ) async throws -> AgentToolResult {
        let files = try await client.listDirectory(at: path)
        return Self.result(invocation, .array(files.map(AgentToolSupport.remoteFileJSON)))
    }

    public init(authentication: AgentSSHAuthenticationRegistry, connections: AgentConnectionPool) {
        self.authentication = authentication
        self.connections = connections
    }
}

nonisolated public struct SFTPStatTool: SFTPToolDefinition {
    public static let name = "sftp_stat"
    public static let summary = "Read remote file metadata."
    public static let safety: AgentToolDescriptor.Safety = .locallyReadOnly
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.sftp_stat", present: present
    )
    public static let presentation = AgentToolDescriptor.Presentation(
        symbol: "info.circle", activity: .semanticArgument(key: "path", fallback: .remoteFile),
        output: .automatic, actionKind: .inspect
    )
    public let authentication: AgentSSHAuthenticationRegistry
    public let connections: AgentConnectionPool
    public func perform(
        client: any SFTPClientProtocol, path: String, arguments: Arguments,
        invocation: AgentToolInvocation
    ) async throws -> AgentToolResult {
        guard let file = try await client.attributes(at: path) else { throw AgentToolError.notFound }
        return Self.result(invocation, AgentToolSupport.remoteFileJSON(file))
    }

    public init(authentication: AgentSSHAuthenticationRegistry, connections: AgentConnectionPool) {
        self.authentication = authentication
        self.connections = connections
    }
}

nonisolated public struct SFTPReadTool: SFTPToolDefinition {
    public static let name = "sftp_read"
    public static let summary = "Read a bounded UTF-8 remote file inline."
    public static let safety: AgentToolDescriptor.Safety = .locallyReadOnly
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.sftp_read", present: present
    )
    public static let presentation = AgentToolDescriptor.Presentation(
        symbol: "doc.text", activity: .semanticArgument(key: "path", fallback: .remoteFile),
        output: .automatic, actionKind: .read
    )
    public let authentication: AgentSSHAuthenticationRegistry
    public let connections: AgentConnectionPool
    public func perform(
        client: any SFTPClientProtocol, path: String, arguments: Arguments,
        invocation: AgentToolInvocation
    ) async throws -> AgentToolResult {
        let data = try await client.readFile(at: path, maximumBytes: 128 * 1_024)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentToolError.invalidArguments("The remote file is not UTF-8 text.")
        }
        return Self.result(
            invocation,
            .object([
                "path": .string(path), "content": .string(text), "bytes": .number(Double(data.count)),
            ]))
    }

    public init(authentication: AgentSSHAuthenticationRegistry, connections: AgentConnectionPool) {
        self.authentication = authentication
        self.connections = connections
    }
}

nonisolated public struct SFTPWriteTool: SFTPToolDefinition {
    public static let name = "sftp_write"
    public static let summary = "Write a bounded UTF-8 remote file atomically."
    public static let safety: AgentToolDescriptor.Safety = .requiresAuthorization
    public static let extraProperties = ["content": string(max: 131_072), "overwrite": boolean()]
    public static let extraRequired = ["content"]
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.sftp_write", present: present
    )
    public static let presentation = AgentToolDescriptor.Presentation(
        symbol: "square.and.pencil",
        activity: .semanticArgument(key: "path", fallback: .remoteFile),
        output: .automatic, actionKind: .write
    )
    public let authentication: AgentSSHAuthenticationRegistry
    public let connections: AgentConnectionPool
    public func perform(
        client: any SFTPClientProtocol, path: String, arguments: Arguments,
        invocation: AgentToolInvocation
    ) async throws -> AgentToolResult {
        try await client.writeFile(
            Data(try arguments.string("content").utf8), at: path,
            overwrite: arguments.optionalBool("overwrite") ?? false)
        return Self.result(invocation, .object(["path": .string(path), "written": .bool(true)]))
    }

    public init(authentication: AgentSSHAuthenticationRegistry, connections: AgentConnectionPool) {
        self.authentication = authentication
        self.connections = connections
    }
}

nonisolated public struct SFTPMkdirTool: SFTPToolDefinition {
    public static let name = "sftp_mkdir"
    public static let summary = "Create a remote directory."
    public static let safety: AgentToolDescriptor.Safety = .requiresAuthorization
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.sftp_mkdir", present: present
    )
    public static let presentation = AgentToolDescriptor.Presentation(
        symbol: "folder.badge.plus",
        activity: .semanticArgument(key: "path", fallback: .remoteFile),
        output: .automatic, actionKind: .create
    )
    public let authentication: AgentSSHAuthenticationRegistry
    public let connections: AgentConnectionPool
    public func perform(
        client: any SFTPClientProtocol, path: String, arguments: Arguments,
        invocation: AgentToolInvocation
    ) async throws -> AgentToolResult {
        try await client.createDirectory(at: path)
        return Self.result(invocation, .object(["path": .string(path), "created": .bool(true)]))
    }

    public init(authentication: AgentSSHAuthenticationRegistry, connections: AgentConnectionPool) {
        self.authentication = authentication
        self.connections = connections
    }
}

nonisolated public struct SFTPMoveTool: SFTPToolDefinition {
    public static let name = "sftp_move"
    public static let summary = "Move or rename a remote path."
    public static let safety: AgentToolDescriptor.Safety = .requiresAuthorization
    public static let extraProperties = ["destination": string(max: 4_096), "overwrite": boolean()]
    public static let extraRequired = ["destination"]
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.sftp_move", present: present
    )
    public static let presentation = AgentToolDescriptor.Presentation(
        symbol: "arrow.right", activity: .semanticArgument(key: "path", fallback: .remoteFile),
        output: .automatic, actionKind: .move
    )
    public let authentication: AgentSSHAuthenticationRegistry
    public let connections: AgentConnectionPool
    public func perform(
        client: any SFTPClientProtocol, path: String, arguments: Arguments,
        invocation: AgentToolInvocation
    ) async throws -> AgentToolResult {
        let destination = try AgentToolSupport.normalizeRemotePath(arguments.string("destination"))
        try await client.rename(
            from: path, to: destination,
            overwrite: arguments.optionalBool("overwrite") ?? false)
        return Self.result(
            invocation,
            .object([
                "source": .string(path), "destination": .string(destination), "moved": .bool(true),
            ]))
    }

    public init(authentication: AgentSSHAuthenticationRegistry, connections: AgentConnectionPool) {
        self.authentication = authentication
        self.connections = connections
    }
}

nonisolated public struct SFTPChmodTool: SFTPToolDefinition {
    public static let name = "sftp_chmod"
    public static let summary = "Change remote POSIX permissions."
    public static let safety: AgentToolDescriptor.Safety = .requiresAuthorization
    public static let extraProperties = ["mode": string(max: 4)]
    public static let extraRequired = ["mode"]
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.sftp_chmod", present: present
    )
    public static let presentation = AgentToolDescriptor.Presentation(
        symbol: "lock", activity: .semanticArgument(key: "path", fallback: .remoteFile),
        output: .automatic, actionKind: .changePermissions
    )
    public let authentication: AgentSSHAuthenticationRegistry
    public let connections: AgentConnectionPool
    public func perform(
        client: any SFTPClientProtocol, path: String, arguments: Arguments,
        invocation: AgentToolInvocation
    ) async throws -> AgentToolResult {
        let raw = try arguments.string("mode")
        guard (3...4).contains(raw.count), raw.allSatisfy({ ("0"..."7").contains(String($0)) }),
            let mode = UInt32(raw, radix: 8)
        else {
            throw AgentToolError.invalidArguments("mode must be a 3- or 4-digit octal value.")
        }
        try await client.setPermissions(at: path, to: mode)
        return Self.result(invocation, .object(["path": .string(path), "mode": .string(raw)]))
    }

    public init(authentication: AgentSSHAuthenticationRegistry, connections: AgentConnectionPool) {
        self.authentication = authentication
        self.connections = connections
    }
}

nonisolated public struct SFTPDeleteTool: SFTPToolDefinition {
    public static let name = "sftp_delete"
    public static let summary = "Permanently delete one remote file or empty directory."
    public static let safety: AgentToolDescriptor.Safety = .requiresAuthorization
    public static let extraProperties = ["kind": enumeration(["file", "directory"])]
    public static let extraRequired = ["kind"]
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.sftp_delete", present: present
    )
    public static let presentation = AgentToolDescriptor.Presentation(
        symbol: "trash", activity: .semanticArgument(key: "path", fallback: .remoteFile),
        output: .automatic, actionKind: .delete
    )
    public let authentication: AgentSSHAuthenticationRegistry
    public let connections: AgentConnectionPool
    public func perform(
        client: any SFTPClientProtocol, path: String, arguments: Arguments,
        invocation: AgentToolInvocation
    ) async throws -> AgentToolResult {
        if try arguments.string("kind") == "directory" {
            try await client.removeDirectory(at: path)
        } else {
            try await client.removeFile(at: path)
        }
        return Self.result(invocation, .object(["path": .string(path), "deleted": .bool(true)]))
    }

    public init(authentication: AgentSSHAuthenticationRegistry, connections: AgentConnectionPool) {
        self.authentication = authentication
        self.connections = connections
    }
}

nonisolated extension SFTPListTool {
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        return F.arrayItems(input) { values in
            let rows = values.compactMap {
                SFTPToolPresentation.remoteFileRow($0, locale: input.locale)
            }
            return [
                .message(String(localized: "\(rows.count) items", locale: input.locale), .secondary),
                .list(
                    .init(
                        title: nil, rows: rows,
                        emptyMessage: F.localized("Directory is empty", locale: input.locale)
                    )),
            ]
        }
    }
}
nonisolated extension SFTPStatTool {
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            F.appendField(
                &items, "Path", object["path"]?.stringValue,
                locale: input.locale, monospaced: true)
            F.appendField(
                &items, "Kind",
                object["kind"]?.stringValue.map {
                    F.kindLabel($0, locale: input.locale)
                }, locale: input.locale)
            if let bytes = object["size"]?.integerValue {
                items.append(F.field("Size", F.byteCount(bytes), locale: input.locale))
            }
            F.appendField(
                &items, "Permissions", object["permissions"]?.stringValue,
                locale: input.locale, monospaced: true)
            F.appendField(
                &items, "Modified", object["modified_at"]?.stringValue.map(F.displayDate),
                locale: input.locale)
            return items
        }
    }
}
nonisolated extension SFTPReadTool {
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            F.appendField(
                &items, "Path", object["path"]?.stringValue,
                locale: input.locale, monospaced: true)
            let content = object["content"]?.stringValue ?? ""
            items.append(
                content.isEmpty
                    ? .message(F.localized("Empty file", locale: input.locale), .secondary)
                    : .text(
                        .init(
                            title: F.localized("Content", locale: input.locale),
                            text: content, style: .monospaced)))
            if let bytes = object["bytes"]?.integerValue {
                items.append(F.field("Size", F.byteCount(bytes), locale: input.locale))
            }
            return items
        }
    }
}
nonisolated extension SFTPWriteTool {
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            F.appendField(
                &items, "Path", object["path"]?.stringValue,
                locale: input.locale, monospaced: true)
            if let content = input.arguments["content"]?.stringValue {
                items.append(F.field("Size", F.byteCount(content.utf8.count), locale: input.locale))
            }
            items.append(
                F.field(
                    "Result", F.localized("Written", locale: input.locale),
                    locale: input.locale))
            return items
        }
    }
}
nonisolated extension SFTPMkdirTool {
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        SFTPToolPresentation.pathDetail(
            input,
            result: AgentToolDetailFormatting.localized(
                "Directory created", locale: input.locale
            )
        )
    }
}
nonisolated extension SFTPMoveTool {
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            F.appendField(
                &items, "Source", object["source"]?.stringValue,
                locale: input.locale, monospaced: true)
            F.appendField(
                &items, "Destination", object["destination"]?.stringValue,
                locale: input.locale, monospaced: true)
            return items
        }
    }
}
nonisolated extension SFTPChmodTool {
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            F.appendField(
                &items, "Path", object["path"]?.stringValue,
                locale: input.locale, monospaced: true)
            F.appendField(
                &items, "Permissions", object["mode"]?.stringValue,
                locale: input.locale, monospaced: true)
            return items
        }
    }
}
nonisolated extension SFTPDeleteTool {
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            F.appendField(
                &items, "Path", object["path"]?.stringValue,
                locale: input.locale, monospaced: true)
            F.appendField(
                &items, "Kind",
                input.arguments["kind"]?.stringValue.map {
                    F.kindLabel($0, locale: input.locale)
                }, locale: input.locale)
            items.append(
                F.field(
                    "Result", F.localized("Deleted", locale: input.locale),
                    locale: input.locale))
            return items
        }
    }
}

nonisolated public enum SFTPToolPresentation {
    public static func remoteFileRow(
        _ value: AgentJSONValue, locale: Locale
    ) -> AgentToolDetail.ListRow? {
        typealias F = AgentToolDetailFormatting
        guard let object = value.objectValue else { return nil }
        let path = object["path"]?.stringValue ?? ""
        let name =
            F.nonempty(object["name"]?.stringValue)
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

    public static func pathDetail(
        _ input: AgentToolDetailInput, result: String
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            F.appendField(
                &items, "Path", object["path"]?.stringValue,
                locale: input.locale, monospaced: true)
            items.append(F.field("Result", result, locale: input.locale))
            return items
        }
    }
}

nonisolated extension AgentToolSupport {

    /// One authenticated SFTP operation. Connection setup may safely retry
    /// after a rejected credential because the operation has not begun. Once
    /// the client is handed to `operation`, a lost connection is only evicted:
    /// replaying a move, delete or write would have unknowable side effects.
    public static func withAuthenticatedSFTP<Value: Sendable>(
        hostID: Host.ID, invocation: AgentToolInvocation,
        context: AgentToolExecutionContext,
        authentication: AgentSSHAuthenticationRegistry, pool: AgentConnectionPool,
        operation: @escaping @Sendable (any SFTPClientProtocol) async throws -> Value
    ) async throws -> Value {
        let client = try await authentication.sftp(
            hostID: hostID, invocationID: invocation.id,
            interaction: context.sshInteraction, pool: pool
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

    /// Internal rather than private because `scratch_pull` and `scratch_push` aim at
    /// the same remote paths the SFTP tools do, and two implementations of "what is
    /// a valid remote path" would be one too many.
    public static func normalizeRemotePath(_ raw: String) throws -> String {
        guard raw.hasPrefix("/"), !raw.contains("\0"), !raw.contains("\r"), !raw.contains("\n") else {
            throw AgentToolError.invalidPath
        }
        var components: [Substring] = []
        for component in raw.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { throw AgentToolError.invalidPath }
                components.removeLast()
            } else {
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    fileprivate static func remoteFileJSON(_ file: RemoteFile) -> AgentJSONValue {
        .object([
            "path": .string(file.path), "name": .string(file.name),
            "kind": .string(file.kind.rawValue), "size": .number(Double(file.size)),
            "permissions": .string(file.octalPermissionDescription),
            "modified_at": file.modifiedAt.map { .string($0.ISO8601Format()) } ?? .null,
        ])
    }
}
