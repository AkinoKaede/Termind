import AgentKit
import Foundation
import TermindApplication
import TermindInfrastructure
import Testing

@Suite @MainActor
struct MCPImportTests {
    @Test func importsSupportedTransportsInNameOrderWithoutConnecting() throws {
        let document = try parse([
            "Zulu": ["url": "https://example.com/mcp", "type": "sse"],
            "Alpha": ["url": "http://localhost:8080/mcp", "headers": ["X-Tenant": "tenant"]],
            "Bravo": ["url": "https://example.com/mcp", "type": "http"],
            "Charlie": ["url": "https://example.com/mcp", "type": "streamable-http"],
            "Delta": ["url": "https://example.com/mcp", "type": "streamableHTTP"],
        ])
        let ai = AIConfigurationModel(persistsSecrets: false)
        let report = ai.importMCP(document)
        #expect(report.importedCount == 5)
        #expect(report.issues.isEmpty)
        #expect(ai.mcpServers.map(\.name) == ["Alpha", "Bravo", "Charlie", "Delta", "Zulu"])
        #expect(ai.mcpServers.last?.transport == .sse)
        #expect(ai.mcpServers.dropLast().allSatisfy { $0.transport == .streamableHTTP })
        #expect(ai.mcpServers.allSatisfy { $0.isEnabled && $0.tools.isEmpty && $0.lastConnectedAt == nil })
        #expect(ai.mcpServers.first?.headers.first?.value == "tenant")
    }

    @Test func namesAndNamespacesRemainUniqueAcrossRepeatedImports() throws {
        let existing = MCPServer(name: "Demo", url: "https://existing.example/mcp")
        let ai = AIConfigurationModel(mcpServers: [existing], persistsSecrets: false)
        let document = try parse([
            "Demo": ["url": "https://example.com/mcp"],
            "demo": ["url": "https://example.com/mcp"],
        ])
        #expect(ai.importMCP(document).importedCount == 2)
        #expect(ai.importMCP(document).importedCount == 2)
        #expect(ai.mcpServers.map(\.name) == ["Demo", "Demo 2", "demo 3", "Demo 4", "demo 5"])
        #expect(Set(ai.mcpServers.map(\.effectiveNamespaceID)).count == 5)
        #expect(ai.mcpServers.first == existing)
    }

    @Test func mixedDocumentsReportUnsupportedEntriesAndKeepValidServers() throws {
        let document = try parse([
            "a": ["command": "node", "args": ["server.js"]],
            "b": ["url": "file:///tmp/mcp"],
            "c": ["url": "https://example.com", "type": "unknown"],
            "d": ["url": "${MCP_URL}"],
            "e": ["url": "https://example.com", "headers": ["X-Tenant": "${TENANT}"]],
            "f": ["url": "https://example.com"],
            "g": ["url": "https://example.com", "headers": ["X-Tenant": 5]],
        ])
        #expect(document.entries.map(\.name) == ["f"])
        #expect(document.issues.map(\.index) == [1, 2, 3, 4, 5, 7])
        #expect(
            document.issues.map(\.problem) == [
                .unsupportedTransport, .invalidURL, .unsupportedTransport, .unresolvedVariable,
                .unresolvedVariable, .invalidEntry,
            ])
        #expect(AIConfigurationModel(persistsSecrets: false).importMCP(document).importedCount == 1)
    }

    @Test func invalidDocumentsFailBeforeAnyWrites() {
        for text in ["{", "[]", "{}", #"{"mcpServers":[]}"#] {
            #expect(throws: MCPImportProblem.invalidDocument) { try MCPImporter.parse(Data(text.utf8)) }
        }
        #expect(throws: MCPImportProblem.invalidDocument) {
            try MCPImporter.parse(Data(repeating: 32, count: MCPImporter.maximumBytes + 1))
        }
    }

    @Test func bearerMaterialIsStoredSeparatelyFromConfiguration() throws {
        let document = try parse([
            "Secure": [
                "url": "https://example.com/mcp",
                "headers": ["authorization": "Bearer fixture-secret", "X-Tenant": "tenant"],
            ]
        ])
        let secrets = ImportSecrets()
        let persistence = ImportPersistence()
        let ai = AIConfigurationModel(persistence: persistence, aiSecrets: secrets)
        #expect(ai.importMCP(document).importedCount == 1)
        let server = try #require(persistence.snapshot.mcpServers.first)
        #expect(server.headers.map(\.name) == ["X-Tenant"])
        #expect(!server.credentialRef.isEmpty)
        #expect(secrets.values[server.credentialRef] == "fixture-secret")
        #expect(!String(describing: persistence.snapshot).contains("fixture-secret"))
    }

    @Test func unsupportedAuthenticationAndVariablesNeverEnterReports() throws {
        let document = try parse([
            "a": ["url": "https://example.com", "headers": ["Authorization": "Basic fixture-secret"]],
            "b": ["url": "https://example.com", "headers": ["X-API-Key": "fixture-secret"]],
            "c": ["url": "https://example.com", "headers": ["Cookie": "fixture-secret"]],
            "d": ["url": "https://user:fixture-secret@example.com"],
            "e": ["url": "https://example.com?api_key=fixture-secret"],
            "f": ["url": "https://example.com", "bearer_token_env_var": "TOKEN"],
            "g": ["url": "https://example.com", "headers": ["Authorization": "Bearer $TOKEN"]],
            "h": ["url": "https://example.com", "headers": ["X-Tenant": "bad\r\nvalue"]],
        ])
        #expect(document.entries.isEmpty)
        let report = AIConfigurationModel(persistsSecrets: false).importMCP(document)
        #expect(report.issues.count == 8)
        #expect(!String(describing: report).contains("fixture-secret"))
    }

    @Test func persistenceFailureRollsBackOnlyTheFailedServerAndItsCredential() throws {
        let persistence = ImportPersistence()
        persistence.failName = "b"
        let secrets = ImportSecrets()
        let ai = AIConfigurationModel(persistence: persistence, aiSecrets: secrets)
        let document = try parse([
            "a": ["url": "https://example.com"],
            "b": ["url": "https://example.com", "headers": ["Authorization": "Bearer fixture-secret"]],
            "c": ["url": "https://example.com"],
        ])
        let report = ai.importMCP(document)
        #expect(report.importedCount == 2)
        #expect(report.issues.map(\.problem) == [.saveFailed])
        #expect(ai.mcpServers.map(\.name) == ["a", "c"])
        #expect(persistence.snapshot.mcpServers.map(\.name) == ["a", "c"])
        #expect(secrets.values.isEmpty)
    }

    @Test func credentialFailureDoesNotCreateAnAnonymousServer() throws {
        let secrets = ImportSecrets()
        secrets.failWrite = true
        let ai = AIConfigurationModel(aiSecrets: secrets)
        let document = try parse([
            "a": ["url": "https://example.com", "headers": ["Authorization": "Bearer fixture-secret"]]
        ])
        let report = ai.importMCP(document)
        #expect(report.importedCount == 0)
        #expect(report.issues.map(\.problem) == [.secretFailed])
        #expect(ai.mcpServers.isEmpty)
        #expect(secrets.values.isEmpty)
    }

    @Test func failedCredentialCleanupIsReported() throws {
        let persistence = ImportPersistence()
        persistence.failName = "a"
        let secrets = ImportSecrets()
        secrets.failRemoval = true
        let ai = AIConfigurationModel(persistence: persistence, aiSecrets: secrets)
        let document = try parse([
            "a": ["url": "https://example.com", "headers": ["Authorization": "Bearer fixture-secret"]]
        ])
        let report = ai.importMCP(document)
        #expect(report.issues.map(\.problem) == [.secretCleanupFailed])
        #expect(ai.mcpServers.isEmpty)
    }

    @Test func readsRegularFilesAndRejectsDirectoriesAndOversizedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "mcp.json")
        try Data(#"{"mcpServers":{"demo":{"url":"https://example.com"}}}"#.utf8).write(to: file)
        #expect(try MCPImporter.read(file).entries.count == 1)
        #expect(throws: MCPImportProblem.unreadableFile) { try MCPImporter.read(directory) }
        try Data(repeating: 32, count: MCPImporter.maximumBytes + 1).write(to: file)
        #expect(throws: MCPImportProblem.unreadableFile) { try MCPImporter.read(file) }
    }

    private func parse(_ servers: [String: Any]) throws -> MCPImportDocument {
        try MCPImporter.parse(JSONSerialization.data(withJSONObject: ["mcpServers": servers]))
    }
}

@MainActor private final class ImportSecrets: AISecretStoring {
    var values: [String: String] = [:]
    var failWrite = false
    var failRemoval = false
    func string(for reference: String) throws -> String? { values[reference] }
    func setString(_ value: String?, for reference: String) throws {
        if value != nil && failWrite || value == nil && failRemoval { throw CocoaError(.fileWriteNoPermission) }
        values[reference] = value
    }
}

@MainActor private final class ImportPersistence: AIConfigurationPersisting {
    var snapshot = AIConfigurationSnapshot(providers: [], roles: [:])
    var failName: String?
    func load() throws -> AIConfigurationSnapshot { snapshot }
    func save(_ snapshot: AIConfigurationSnapshot) throws {
        if let failName, snapshot.mcpServers.contains(where: { $0.name == failName }) {
            throw CocoaError(.fileWriteNoPermission)
        }
        self.snapshot = snapshot
    }
}
