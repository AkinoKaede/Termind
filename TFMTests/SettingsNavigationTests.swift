import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

struct SettingsNavigationTests {
    @Test @MainActor
    func legacySearchSettingsAndSecretAreRemoved() throws {
        let suite = "LegacyWebSearchSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("brave", forKey: LegacyWebSearchSettings.backendKey)
        defaults.set("https://search.example", forKey: LegacyWebSearchSettings.baseURLKey)
        defaults.set("termind.ai.search.old", forKey: LegacyWebSearchSettings.credentialReferenceKey)
        var deleted: [String] = []

        LegacyWebSearchSettings.remove(defaults: defaults) { deleted.append($0) }

        #expect(deleted == ["termind.ai.search.old"])
        #expect(defaults.object(forKey: LegacyWebSearchSettings.backendKey) == nil)
        #expect(defaults.object(forKey: LegacyWebSearchSettings.baseURLKey) == nil)
        #expect(defaults.object(forKey: LegacyWebSearchSettings.credentialReferenceKey) == nil)
    }

    @Test @MainActor
    func failedLegacySecretDeletionKeepsReferenceForRetry() throws {
        let suite = "LegacyWebSearchSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("termind.ai.search.old", forKey: LegacyWebSearchSettings.credentialReferenceKey)

        LegacyWebSearchSettings.remove(defaults: defaults) { _ in
            throw CocoaError(.fileWriteNoPermission)
        }

        #expect(
            defaults.string(forKey: LegacyWebSearchSettings.credentialReferenceKey)
                == "termind.ai.search.old"
        )
    }

    @Test
    func detailRoutesExposeTheirParentRoute() {
        let providerID = UUID()
        let serverID = UUID()

        #expect(SettingsRoute.index.parent == nil)
        #expect(SettingsRoute.category(.terminal).parent == .index)
        #expect(SettingsRoute.modelProvider(providerID).parent == .category(.ai))
        #expect(
            SettingsRoute.providerModels(providerID).parent
                == .modelProvider(providerID)
        )
        #expect(SettingsRoute.mcpServer(serverID, isNew: false).parent == .category(.ai))
        #expect(SettingsRoute.localMCPServer.parent == .category(.ai))
        #expect(SettingsRoute.terminalConfiguration(.dark).parent == .category(.terminal))
    }

    @Test @MainActor
    func settingsRestoresTheDestinationItReplaced() {
        let workspace = Workspace(pane: Pane(.empty))
        let window = WindowModel(workspaces: [workspace])

        window.openSettings(route: .category(.terminal))
        #expect(window.selectedDestination == .settings)
        #expect(window.settingsRoute == .category(.terminal))

        window.closeSettings()
        #expect(window.selectedDestination == .workspace(workspace.id))
        #expect(window.settingsRoute == .index)
    }

    @Test @MainActor
    func settingsFallsBackToVaultWhenItsWorkspaceDisappears() {
        let workspace = Workspace(pane: Pane(.empty))
        let window = WindowModel(workspaces: [workspace])

        window.openSettings()
        window.workspaces.removeAll()
        window.closeSettings()

        #expect(window.selectedDestination == .vault)
    }

    @Test @MainActor
    func settingsToolbarBackWalksTheRouteThenRestoresContent() {
        let window = WindowModel()
        window.openSettings(route: .terminalConfiguration(.dark))

        window.navigateBackInSettings()
        #expect(window.settingsRoute == .category(.terminal))
        #expect(window.selectedDestination == .settings)

        window.navigateBackInSettings()
        #expect(window.settingsRoute == .index)
        #expect(window.selectedDestination == .settings)

        window.navigateBackInSettings()
        #expect(window.selectedDestination == .vault)
    }

    @Test @MainActor
    func navigatorAndAssistantRoundTripThroughSettings() {
        let window = WindowModel()
        window.openSettings(route: .category(.app))

        window.activateSidebarMode(.assistant)
        #expect(window.selectedDestination == .assistant)
        #expect(window.sidebarMode == .assistant)

        window.activateSidebarMode(.navigation)
        #expect(window.selectedDestination == .settings)
        #expect(window.settingsRoute == .category(.app))
        #expect(window.sidebarMode == .navigation)
    }

    @Test
    func emptyProviderDraftIsDiscarded() {
        let provider = ModelProvider(name: String(localized: "New Provider"))
        #expect(SettingsDraftPolicy.shouldDiscard(provider))
    }

    @Test
    func configuredProviderDraftIsKept() {
        var provider = ModelProvider(name: String(localized: "New Provider"))
        provider.inferenceURL = "https://example.com/v1/chat/completions"
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
        existingTool.accessPolicy = .deny
        let existingAsk = MCPTool(id: "existing-ask", accessPolicy: .ask)
        let existingApprove = MCPTool(id: "existing-approve", accessPolicy: .approve)
        var server = MCPServer(name: "Gateway")
        server.tools = [existingTool, existingAsk, existingApprove]
        let store = AIConfigurationModel(mcpServers: [server], persistsSecrets: false)

        store.setTools(
            [
                MCPTool(
                    id: "search", title: "Updated",
                    annotations: MCPToolAnnotations(readOnlyHint: true)
                ),
                MCPTool(
                    id: "existing-ask",
                    annotations: MCPToolAnnotations(readOnlyHint: true)
                ),
                MCPTool(id: "existing-approve"),
                MCPTool(
                    id: "new-read-only",
                    annotations: MCPToolAnnotations(readOnlyHint: true)
                ),
                MCPTool(
                    id: "new-not-read-only",
                    annotations: MCPToolAnnotations(readOnlyHint: false)
                ),
                MCPTool(id: "new-without-hint"),
                MCPTool(
                    id: "new-conflicting-hints",
                    annotations: MCPToolAnnotations(readOnlyHint: true, destructiveHint: true)
                ),
            ],
            version: "2025-06-18", for: server.id
        )

        let rediscovered = try #require(store.mcpServer(server.id))
        #expect(rediscovered.tools.first { $0.id == "search" }?.accessPolicy == .deny)
        #expect(rediscovered.tools.first { $0.id == "existing-ask" }?.accessPolicy == .ask)
        #expect(rediscovered.tools.first { $0.id == "existing-approve" }?.accessPolicy == .approve)
        #expect(rediscovered.tools.first { $0.id == "new-read-only" }?.accessPolicy == .approve)
        #expect(rediscovered.tools.first { $0.id == "new-not-read-only" }?.accessPolicy == .ask)
        #expect(rediscovered.tools.first { $0.id == "new-without-hint" }?.accessPolicy == .ask)
        #expect(rediscovered.tools.first { $0.id == "new-conflicting-hints" }?.accessPolicy == .ask)

        store.setToolAccessPolicy(.approve, tool: "search", on: server.id)
        #expect(
            store.mcpServer(server.id)?.tools.first { $0.id == "search" }?.accessPolicy
                == .approve
        )
    }

    @Test
    func destructiveMCPToolsCanBeApprovedAndDeniedToolsStayAvailable() throws {
        var destructive = MCPTool(id: "destroy", accessPolicy: .approve)
        destructive.annotations.destructiveHint = true
        let denied = MCPTool(id: "denied", accessPolicy: .deny)
        let server = MCPServer(name: "Gateway", tools: [destructive, denied])
        let store = AIConfigurationModel(mcpServers: [server], persistsSecrets: false)

        let normalized = try #require(store.mcpServer(server.id))
        #expect(normalized.tools[0].accessPolicy == .approve)
        #expect(store.availableTools.map(\.tool.id).contains("denied"))

        store.setToolAccessPolicy(.approve, tool: "destroy", on: server.id)
        #expect(store.mcpServer(server.id)?.tools[0].accessPolicy == .approve)

        var newlyDestructive = MCPTool(id: "denied", accessPolicy: .ask)
        newlyDestructive.annotations.destructiveHint = true
        store.setToolAccessPolicy(.approve, tool: "denied", on: server.id)
        store.setTools([newlyDestructive], version: "2025-06-18", for: server.id)
        #expect(store.mcpServer(server.id)?.tools[0].accessPolicy == .approve)
    }
}
