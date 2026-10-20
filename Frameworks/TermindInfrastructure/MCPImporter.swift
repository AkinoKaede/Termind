// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Darwin
import Foundation
import TermindApplication

public nonisolated enum MCPImporter {
    public static let maximumBytes = 1_048_576

    public static func read(_ url: URL) throws -> MCPImportDocument {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw MCPImportProblem.unreadableFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size <= maximumBytes
        else { throw MCPImportProblem.unreadableFile }
        let data: Data
        do { data = try handle.read(upToCount: maximumBytes + 1) ?? Data() } catch {
            throw MCPImportProblem.unreadableFile
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> MCPImportDocument {
        guard data.count <= maximumBytes,
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let servers = root["mcpServers"] as? [String: Any]
        else { throw MCPImportProblem.invalidDocument }
        var entries: [MCPImportEntry] = []
        var issues: [MCPImportIssue] = []
        for (offset, key) in servers.keys.sorted().enumerated() {
            let index = offset + 1
            do {
                entries.append(try parseEntry(servers[key], name: key, index: index))
            } catch {
                issues.append(.init(index: index, problem: error as? MCPImportProblem ?? .invalidEntry))
            }
        }
        return MCPImportDocument(entries: entries, issues: issues)
    }

    private static func parseEntry(_ value: Any?, name: String, index: Int) throws -> MCPImportEntry {
        guard let object = value as? [String: Any] else { throw MCPImportProblem.invalidEntry }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !MCPToolNaming.namespaceID(from: name).isEmpty else { throw MCPImportProblem.invalidEntry }
        guard object["command"] == nil, object["args"] == nil, object["env"] == nil else {
            throw MCPImportProblem.unsupportedTransport
        }
        let transport: MCPServer.Transport
        switch object["type"] {
        case nil: transport = .streamableHTTP
        case let type as String:
            switch type {
            case "http", "streamable-http", "streamableHTTP": transport = .streamableHTTP
            case "sse": transport = .sse
            default: throw MCPImportProblem.unsupportedTransport
            }
        default: throw MCPImportProblem.unsupportedTransport
        }
        guard let rawURL = object["url"] as? String else { throw MCPImportProblem.invalidURL }
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hasVariable(url) else { throw MCPImportProblem.unresolvedVariable }
        guard let components = URLComponents(string: url),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            let host = components.host, !host.isEmpty, components.url != nil,
            !url.contains(where: { $0.isWhitespace }), components.fragment == nil,
            components.port.map({ (1...65535).contains($0) }) ?? true
        else { throw MCPImportProblem.invalidURL }
        guard components.user == nil, components.password == nil,
            !(components.queryItems ?? []).contains(where: { isSensitive($0.name) }),
            !object.keys.contains(where: { isSensitive($0) })
        else { throw MCPImportProblem.unsupportedAuthentication }
        var headers: [MCPHeader] = []
        var bearer: String?
        if let rawHeaders = object["headers"] {
            guard let values = rawHeaders as? [String: String] else { throw MCPImportProblem.invalidEntry }
            var seen = Set<String>()
            let allowed = CharacterSet(
                charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
            for key in values.keys.sorted() {
                let value = values[key]!
                guard !key.isEmpty, key.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                    !value.contains("\r"), !value.contains("\n"),
                    seen.insert(key.lowercased()).inserted
                else { throw MCPImportProblem.invalidEntry }
                guard !hasVariable(value) else { throw MCPImportProblem.unresolvedVariable }
                if key.lowercased() == "authorization" {
                    let parts = value.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                    guard parts.count == 2, parts[0].lowercased() == "bearer",
                        !parts[1].contains(where: { $0.isWhitespace })
                    else { throw MCPImportProblem.unsupportedAuthentication }
                    bearer = String(parts[1])
                } else {
                    guard !isSensitive(key) else { throw MCPImportProblem.unsupportedAuthentication }
                    headers.append(MCPHeader(name: key, value: value))
                }
            }
        }
        return MCPImportEntry(
            index: index, name: name, transport: transport, url: url, headers: headers, bearerToken: bearer)
    }

    private static func hasVariable(_ value: String) -> Bool {
        value.contains("${") || value.contains("{{")
            || value.range(of: #"\$[A-Za-z_]|%[A-Za-z_][A-Za-z0-9_]*%"#, options: .regularExpression) != nil
    }

    private static func isSensitive(_ key: String) -> Bool {
        let key = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return ["authorization", "authentication", "apikey", "token", "secret", "password", "cookie", "credential"]
            .contains(where: { key.contains($0) }) || key == "auth" || key == "oauth"
    }
}
