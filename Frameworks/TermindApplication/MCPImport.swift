import AgentKit
import Foundation

/// Transient import data. Bearer material must never be included in the persisted server or report.
public nonisolated struct MCPImportEntry: Sendable {
    public let index: Int
    public let name: String
    public let transport: MCPServer.Transport
    public let url: String
    public let headers: [MCPHeader]
    public let bearerToken: String?

    public init(
        index: Int, name: String, transport: MCPServer.Transport, url: String,
        headers: [MCPHeader], bearerToken: String?
    ) {
        self.index = index
        self.name = name
        self.transport = transport
        self.url = url
        self.headers = headers
        self.bearerToken = bearerToken
    }
}

public nonisolated enum MCPImportProblem: Error, Equatable, Sendable {
    case unreadableFile, invalidDocument, invalidEntry, unsupportedTransport, invalidURL
    case unresolvedVariable, unsupportedAuthentication, saveFailed, secretFailed, secretCleanupFailed
}

public nonisolated struct MCPImportIssue: Sendable {
    public let index: Int
    public let problem: MCPImportProblem

    public init(index: Int, problem: MCPImportProblem) {
        self.index = index
        self.problem = problem
    }
}

public nonisolated struct MCPImportDocument: Sendable {
    public let entries: [MCPImportEntry]
    public let issues: [MCPImportIssue]

    public init(entries: [MCPImportEntry], issues: [MCPImportIssue]) {
        self.entries = entries
        self.issues = issues
    }
}

public nonisolated struct MCPImportReport: Sendable {
    public let importedCount: Int
    public let issues: [MCPImportIssue]
}

extension AIConfigurationModel {
    /// Saves each server independently; one failed entry never replaces an existing server.
    public func importMCP(_ document: MCPImportDocument) -> MCPImportReport {
        var issues = document.issues
        var importedCount = 0
        for entry in document.entries {
            let base = entry.name
            var name = base
            var suffix = 2
            while mcpServers.contains(where: {
                $0.name == name || $0.effectiveNamespaceID == MCPToolNaming.namespaceID(from: name)
            }) {
                name = "\(base) \(suffix)"
                suffix += 1
            }
            var server = MCPServer(name: name, transport: entry.transport, url: entry.url, headers: entry.headers)
            if let token = entry.bearerToken {
                server.credentialRef = Self.makeCredentialRef("mcp")
                setSecret(token, for: server.credentialRef)
                if secretStorageError != nil {
                    setSecret(nil, for: server.credentialRef)
                    issues.append(
                        .init(
                            index: entry.index,
                            problem: secretStorageError == nil ? .secretFailed : .secretCleanupFailed))
                    continue
                }
            }
            upsert(server)
            if mcpServer(server.id) == nil {
                setSecret(nil, for: server.credentialRef)
                issues.append(
                    .init(
                        index: entry.index,
                        problem: server.credentialRef.isEmpty || secretStorageError == nil
                            ? .saveFailed : .secretCleanupFailed))
                continue
            }
            importedCount += 1
        }
        return MCPImportReport(importedCount: importedCount, issues: issues.sorted { $0.index < $1.index })
    }
}
