import Foundation
import Testing

@testable import Termind

struct SettingsNavigationTests {
    @Test
    func detailRoutesKeepTheirSidebarSelection() {
        let providerID = UUID()
        let serverID = UUID()

        #expect(SettingsRoute.modelProvider(providerID, isNew: false).section == .providers)
        #expect(SettingsRoute.providerModels(providerID, isNew: true).section == .providers)
        #expect(SettingsRoute.mcpServer(serverID, isNew: false).section == .mcp)
        #expect(SettingsRoute.terminalConfiguration(.dark).section == .terminalAppearance)
    }

    @Test
    func emptyProviderDraftIsDiscarded() {
        let provider = ModelProvider(name: String(localized: "New Provider"))
        #expect(SettingsDraftPolicy.shouldDiscard(provider))
    }

    @Test
    func configuredProviderDraftIsKept() {
        var provider = ModelProvider(name: String(localized: "New Provider"))
        provider.baseURL = "https://example.com/v1"
        #expect(!SettingsDraftPolicy.shouldDiscard(provider))

        provider = ModelProvider(name: "Work")
        #expect(!SettingsDraftPolicy.shouldDiscard(provider))
    }

    @Test
    func emptyServerDraftIsDiscarded() {
        let server = MCPServer(name: "", namespaceID: "")
        #expect(SettingsDraftPolicy.shouldDiscard(server))
    }

    @Test
    func configuredServerDraftIsKept() {
        var server = MCPServer(name: "", namespaceID: "")
        server.url = "https://example.com/mcp"
        #expect(SettingsDraftPolicy.shouldDiscard(server))

        server = MCPServer(name: "Production")
        #expect(!SettingsDraftPolicy.shouldDiscard(server))
    }

    @Test(arguments: [
        ("A B C-D", "a_b_c-d"),
        ("  Alpha!!!Beta  ", "alpha_beta"),
        ("__Alpha--", "alpha"),
        ("MIXED_case-42", "mixed_case-42"),
        ("中文", ""),
        ("A中B", "a_b"),
        ("...", ""),
    ])
    func mcpNamespaceIDNormalization(input: String, expected: String) {
        #expect(MCPToolNaming.namespaceID(from: input) == expected)
    }

    @Test
    func mcpNamespaceLocksAndRejectsDuplicates() throws {
        let existing = MCPServer(name: "A B C-D")
        var draft = MCPServer(name: "", namespaceID: "")
        let store = AIConfigurationModel(
            mcpServers: [existing, draft], persistsSecrets: false
        )

        draft.name = "Other Gateway"
        store.upsert(draft)
        #expect(store.lockMCPNamespace(for: draft.id))
        #expect(store.mcpServer(draft.id)?.namespaceID == "other_gateway")

        var renamed = try #require(store.mcpServer(draft.id))
        renamed.name = "Renamed"
        store.upsert(renamed)
        #expect(store.mcpServer(draft.id)?.effectiveNamespaceID == "other_gateway")

        let duplicate = MCPServer(name: "A!!!B C-D", namespaceID: "")
        store.upsert(duplicate)
        #expect(!store.lockMCPNamespace(for: duplicate.id))
        #expect(store.mcpServer(duplicate.id)?.namespaceID == "")
    }

    @Test
    func mcpToolAccessPolicyIsAtomicAndSurvivesRediscovery() throws {
        var existingTool = MCPTool(id: "search")
        existingTool.accessPolicy = .disabled
        var server = MCPServer(name: "Gateway")
        server.tools = [existingTool]
        let store = AIConfigurationModel(mcpServers: [server], persistsSecrets: false)

        store.setTools(
            [MCPTool(id: "search", title: "Updated"), MCPTool(id: "new-tool")],
            version: "2025-06-18", for: server.id
        )

        let rediscovered = try #require(store.mcpServer(server.id))
        #expect(rediscovered.tools.first { $0.id == "search" }?.accessPolicy == .disabled)
        #expect(rediscovered.tools.first { $0.id == "new-tool" }?.accessPolicy == .alwaysAsk)

        store.setToolAccessPolicy(.followPermissions, tool: "search", on: server.id)
        #expect(
            store.mcpServer(server.id)?.tools.first { $0.id == "search" }?.accessPolicy
                == .followPermissions
        )
    }
}
