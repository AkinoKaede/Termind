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
        let server = MCPServer(name: String(localized: "New Server"))
        #expect(SettingsDraftPolicy.shouldDiscard(server))
    }

    @Test
    func configuredServerDraftIsKept() {
        var server = MCPServer(name: String(localized: "New Server"))
        server.url = "https://example.com/mcp"
        #expect(!SettingsDraftPolicy.shouldDiscard(server))

        server = MCPServer(name: "Production")
        #expect(!SettingsDraftPolicy.shouldDiscard(server))
    }
}
