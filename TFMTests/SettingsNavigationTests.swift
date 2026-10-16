import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import Testing

@testable import Termind

struct SettingsNavigationTests {
    @Test @MainActor
    func autosaveDoesNotRemoveTheSpaceBetweenWordsWhileTypingAName() throws {
        let model = TerminalSettingsModel()
        let window = WindowModel()
        let theme = TerminalCustomTheme(name: "", appearance: .both, baseThemeName: "Termind Dark")
        window.openSettings(route: .terminalCustomThemes)
        window.beginEditingTerminalTheme(theme, isNew: true, in: model)
        let draft = try #require(window.terminalThemeDraft)
        draft.value.name = "Ocean "
        window.saveTerminalThemeChanges(allowNameTrimming: false)
        #expect(draft.value.name == "Ocean ")
        draft.value.name += "Blue "
        window.navigateBackInSettings()
        #expect(model.themeLibrary.themes.first?.name == "Ocean Blue")
        #expect(!window.showsDiscardTerminalTheme)
    }

    @Test(arguments: [false, true]) @MainActor
    func themeEditsSaveBeforeBackOrChangingDestinations(changesDestination: Bool) throws {
        let model = TerminalSettingsModel()
        let window = WindowModel()
        let theme = TerminalCustomTheme(name: "Personal", appearance: .both, baseThemeName: "Termind Dark")
        model.saveCustomTheme(theme, isNew: true)
        window.openSettings(route: .terminalCustomThemes)
        window.beginEditingTerminalTheme(theme, isNew: false, in: model)
        let draft = try #require(window.terminalThemeDraft)
        draft.value.configuration = "background = 123456"
        if changesDestination { window.selectVault() } else { window.navigateBackInSettings() }
        #expect(model.themeLibrary.themes.first?.configuration == "background = 123456")
        #expect(!draft.isDirty)
        #expect(!window.showsDiscardTerminalTheme)
        #expect(window.terminalThemeDraft == nil)
        #expect(window.settingsRoute == .terminalCustomThemes)
        #expect(window.selectedDestination == (changesDestination ? .vault : .settings))
    }

    @Test @MainActor
    func invalidOrDeletedDraftsRemainProtectedAndDiscardCannotResurrectThem() throws {
        let model = TerminalSettingsModel()
        let window = WindowModel()
        let theme = TerminalCustomTheme(name: "Personal", appearance: .both, baseThemeName: "Termind Dark")
        model.saveCustomTheme(theme, isNew: true)
        window.openSettings(route: .terminalCustomThemes)
        window.beginEditingTerminalTheme(theme, isNew: false, in: model)
        let draft = try #require(window.terminalThemeDraft)
        draft.value.name = " "
        window.navigateBackInSettings()
        #expect(window.showsDiscardTerminalTheme)
        #expect(model.themeLibrary.themes.first?.name == "Personal")
        window.cancelTerminalThemeNavigation()
        draft.value.name = "Recovered"
        model.deleteCustomTheme(id: theme.id)
        window.navigateBackInSettings()
        #expect(window.showsDiscardTerminalTheme)
        window.discardTerminalThemeAndNavigate()
        window.saveTerminalThemeChanges()
        #expect(model.themeLibrary.themes.isEmpty)
        #expect(window.terminalThemeDraft == nil)
    }

    @Test @MainActor
    func failedAutosavePreservesDraftAndProtectsNavigationUntilRetry() throws {
        let store = UnavailableThemeStore()
        let model = TerminalSettingsModel(persistence: store)
        let window = WindowModel()
        let theme = TerminalCustomTheme(name: "", appearance: .both, baseThemeName: "Termind Dark")
        window.openSettings(route: .terminalCustomThemes)
        window.beginEditingTerminalTheme(theme, isNew: true, in: model)
        let draft = try #require(window.terminalThemeDraft)
        draft.value.name = "New"
        window.navigateBackInSettings()
        #expect(window.showsDiscardTerminalTheme)
        #expect(draft.isDirty)
        #expect(model.themeLibrary.themes.isEmpty)
        #expect(model.storageError != nil)
        window.cancelTerminalThemeNavigation()
        store.fails = false
        window.navigateBackInSettings()
        #expect(!window.showsDiscardTerminalTheme)
        #expect(window.terminalThemeDraft == nil)
        #expect(model.themeLibrary.themes.first?.name == "New")
    }

    @Test @MainActor
    func failedDuplicateSaveIsProtectedEvenBeforeFurtherEdits() {
        let store = UnavailableThemeStore()
        let model = TerminalSettingsModel(persistence: store)
        let window = WindowModel()
        let theme = TerminalCustomTheme(name: "Personal Copy", appearance: .both, baseThemeName: "Termind Dark")
        window.openSettings(route: .terminalCustomThemes)
        window.beginEditingTerminalTheme(theme, isNew: true, in: model)
        #expect(window.terminalThemeDraft?.isDirty == false)
        window.navigateBackInSettings()
        #expect(window.hasUnsavedTerminalThemeChanges)
        #expect(window.showsDiscardTerminalTheme)
        #expect(window.settingsRoute == .terminalCustomTheme(theme.id))
    }

    @Test @MainActor
    func dirtyThemeProtectsBackNavigationAndChangingDestinations() {
        let window = WindowModel()
        let theme = TerminalCustomTheme(name: "Personal", appearance: .both, baseThemeName: "Termind Dark")
        window.openSettings(route: .terminalCustomThemes)
        window.terminalThemeDraft = .init(theme, isNew: false)
        window.settingsRoute = .terminalCustomTheme(theme.id)
        window.terminalThemeDraft?.value.name = "Unsaved"
        window.navigateBackInSettings()
        #expect(window.settingsRoute == .terminalCustomTheme(theme.id))
        #expect(window.showsDiscardTerminalTheme)
        window.cancelTerminalThemeNavigation()
        #expect(window.terminalThemeDraft?.value.name == "Unsaved")
        window.selectVault()
        #expect(window.selectedDestination == .settings)
        #expect(window.showsDiscardTerminalTheme)
        window.discardTerminalThemeAndNavigate()
        #expect(window.selectedDestination == .vault)
        #expect(window.terminalThemeDraft == nil)
        #expect(!window.showsDiscardTerminalTheme)
    }

    @Test(
        arguments: [
            EntitlementStatus.free, .purchased(.purchased), .purchased(.familyShared),
            .subscription(
                ProSubscriptionStatus(
                    phase: .subscribed, expiresAt: .distantFuture, willAutoRenew: true, ownership: .purchased)),
        ]) @MainActor
    func proPresentationLeavesSettingsNavigationAndReturnDestinationIntact(status: EntitlementStatus) {
        let workspace = Workspace(pane: Pane(.empty))
        let window = WindowModel(workspaces: [workspace])
        let pro = ProAccessController.testing(status: status)
        window.openSettings()

        pro.presentPaywall()

        #expect(pro.isPaywallPresented)
        #expect(window.settingsRoute == .index)
        #expect(window.selectedDestination == .settings)
        #expect(SettingsCategory(rawValue: "pro") == nil)
        pro.isPaywallPresented = false
        window.settingsRoute = .category(.terminal)
        window.navigateBackInSettings()
        #expect(window.settingsRoute == .index)
        window.navigateBackInSettings()
        #expect(window.selectedDestination == .workspace(workspace.id))
    }

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
        #expect(SettingsRoute.category(.notifications).parent == .index)
        #expect(SettingsCategory.notifications.symbol == "bell.badge")
        #expect(SettingsRoute.category(.terminal).parent == .index)
        #expect(SettingsRoute.modelProvider(providerID).parent == .category(.ai))
        #expect(
            SettingsRoute.providerModels(providerID).parent
                == .modelProvider(providerID)
        )
        #expect(SettingsRoute.mcpServer(serverID, isNew: false).parent == .category(.ai))
        #expect(SettingsRoute.localMCPServer.parent == .category(.ai))
        #expect(SettingsRoute.terminalCustomTheme(UUID()).parent == .terminalCustomThemes)
        #expect(SettingsRoute.terminalThemes(.dark).parent == .category(.terminal))
        #expect(SettingsRoute.logging.parent == .index)
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
        window.openSettings(route: .terminalCustomTheme(UUID()))

        window.navigateBackInSettings()
        #expect(window.settingsRoute == .terminalCustomThemes)

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

    @Test(arguments: ["", " \t\n "])
    func emptyProviderDraftIsDiscarded(name: String) {
        var provider = ModelProvider(name: name)
        provider.inferenceURL = " \t\n "
        #expect(SettingsDraftPolicy.shouldDiscard(provider))
    }

    @Test
    func configuredProviderDraftIsKept() {
        var provider = ModelProvider(name: "")
        provider.inferenceURL = "https://example.com/v1/chat/completions"
        #expect(!SettingsDraftPolicy.shouldDiscard(provider))

        provider = ModelProvider(name: "")
        provider.credentialRef = "test-credential"
        #expect(!SettingsDraftPolicy.shouldDiscard(provider))

        provider = ModelProvider(name: "")
        provider.models = [AIModel(id: "test-model")]
        #expect(!SettingsDraftPolicy.shouldDiscard(provider))
    }

    @Test(arguments: ["Work", "New Provider", String(localized: "New Provider")])
    func namedProviderDraftIsKept(name: String) {
        let provider = ModelProvider(name: name)
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

@MainActor private final class UnavailableThemeStore: TerminalPreferencesPersisting {
    var fails = true
    func loadTerminal() throws -> TerminalPreferences { .init() }
    func saveTerminal(_ value: TerminalPreferences) throws {}
    func saveTerminalThemes(_ value: TerminalThemeLibrary) throws {
        if fails { throw CocoaError(.fileWriteUnknown) }
    }
}
