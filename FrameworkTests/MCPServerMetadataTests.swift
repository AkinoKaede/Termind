// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@Suite @MainActor
struct MCPServerMetadataTests {
    @Test func rediscoveryReplacesAndClearsTheDescriptionWithoutResettingAccessPolicy() {
        let tool = MCPTool(id: "search", accessPolicy: .approve)
        let server = MCPServer(name: "Docs", serverDescription: "Old description", tools: [tool])
        let model = AIConfigurationModel(mcpServers: [server])
        model.setTools(
            [MCPTool(id: tool.id)], version: "2026-07-28", serverDescription: "Search documents.", for: server.id)
        #expect(model.mcpServer(server.id)?.serverDescription == "Search documents.")
        #expect(model.mcpServer(server.id)?.tools.first?.accessPolicy == .approve)
        model.setTools([MCPTool(id: tool.id)], version: "2026-07-28", for: server.id)
        #expect(model.mcpServer(server.id)?.serverDescription == nil)
    }

    @Test func syncedMetadataRoundTripsAndOlderPayloadsRemainReadable() throws {
        let server = MCPServer(name: "Docs", serverDescription: "Search documents.")
        let encoded = try JSONEncoder().encode(SyncedMCPServer(server, sortIndex: 0))
        let decoded = try JSONDecoder().decode(SyncedMCPServer.self, from: encoded)
        #expect(decoded.value.serverDescription == server.serverDescription)
        var old = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "serverDescription")
        let legacy = try JSONDecoder().decode(
            SyncedMCPServer.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.value.serverDescription == nil)
        #expect(legacy.value.id == server.id)
    }

    @Test func historicalServerSurvivesMigrationAndDescriptionSurvivesReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("metadata.store")
        let server = MCPServer(
            name: "Docs", url: "https://docs.test/mcp",
            tools: [MCPTool(id: "search", accessPolicy: .approve)])
        try writeHistoricalServer(server, to: url)
        try upgradeAndSaveDescription(server, at: url)
        let reopened = try TermindPersistence.makeContainer(url: url)
        let restored = try #require(AIPersistence(context: reopened.mainContext).load().mcpServers.first)
        #expect(restored.id == server.id)
        #expect(restored.tools == server.tools)
        #expect(restored.serverDescription == "Search documents.")
    }

    private func writeHistoricalServer(_ server: MCPServer, to url: URL) throws {
        let schema = Schema(versionedSchema: TermindSchemaV58.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)])
        container.mainContext.insert(PersistentMCPServer(server, sortIndex: 0))
        try container.mainContext.save()
    }

    private func upgradeAndSaveDescription(_ server: MCPServer, at url: URL) throws {
        let container = try TermindPersistence.makeContainer(url: url)
        let store = AIPersistence(context: container.mainContext)
        var snapshot = try store.load()
        #expect(snapshot.mcpServers.first?.id == server.id)
        #expect(snapshot.mcpServers.first?.serverDescription == nil)
        snapshot.mcpServers[0].serverDescription = "Search documents."
        try store.save(snapshot)
    }
}
