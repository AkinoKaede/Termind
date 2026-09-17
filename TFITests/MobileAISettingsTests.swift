import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileAISettingsTests {
    private func provider() -> ModelProvider {
        var value = ModelProvider(name: "Gateway", inferenceURL: "https://example.invalid/v1/responses")
        value.models = [AIModel(id: "one"), AIModel(id: "two")]
        return value
    }

    @Test func providerModelsStayInDraftAndSaveWithReferenceCleanup() throws {
        let provider = provider()
        let ai = AIConfigurationModel(modelProviders: [provider])
        let ref = AIModelRef(modelProviderID: provider.id, modelID: "one")
        ai.assign(ref, to: .chat)
        ai.select(ref)
        let editor = MobileProviderEditorModel(ai: ai, provider: provider)
        #expect(!editor.hasExistingKey)
        #expect(!editor.requiresKey)
        #expect(editor.keyAction == .preserve)
        editor.remove(["one"])
        editor.add(id: "new-model")
        editor.endpoint.url = "https://changed.invalid/v1"
        #expect(ai.modelProvider(provider.id) == provider)
        #expect(ai.assignment(for: .chat) == ref)
        try editor.save()
        #expect(ai.modelProvider(provider.id)?.models.map(\.id) == ["two", "new-model"])
        #expect(ai.roles[.chat] == nil)
        #expect(ai.lastSelectedModel == nil)
        #expect(ai.modelProvider(provider.id)?.inferenceURL.contains("changed.invalid") == true)
    }

    @Test func editsMergeSeparateModelFieldsAndKeepRemoteAdditions() throws {
        let provider = provider()
        let ai = AIConfigurationModel(modelProviders: [provider])
        let editor = MobileProviderEditorModel(ai: ai, provider: provider)
        editor.draft.models[0].displayName = "Local name"
        var remote = provider.models[0]
        remote.contextLength = 12345
        ai.updateModel(remote, in: provider.id)
        ai.addModel(AIModel(id: "remote"), to: provider.id)
        try editor.save()
        let saved = try #require(ai.modelProvider(provider.id))
        #expect(saved.models[0].displayName == "Local name")
        #expect(saved.models[0].contextLength == 12345)
        #expect(saved.models.map(\.id) == ["one", "two", "remote"])
    }

    @Test func modelSheetSaveOnlyUpdatesTheProviderDraft() {
        let provider = provider()
        let ai = AIConfigurationModel(modelProviders: [provider])
        let editor = MobileProviderEditorModel(ai: ai, provider: provider)
        var changed = provider.models[0]
        changed.displayName = "Edited in sheet"

        editor.update(changed)

        #expect(editor.draft.models[0].displayName == "Edited in sheet")
        #expect(ai.modelProvider(provider.id)?.models[0].displayName.isEmpty == true)
    }

    @Test func simultaneousModelFieldChangesKeepDraftAndRejectSave() throws {
        let provider = provider()
        let ai = AIConfigurationModel(modelProviders: [provider])
        let editor = MobileProviderEditorModel(ai: ai, provider: provider)
        editor.draft.models[0].displayName = "Local"
        var remote = provider.models[0]
        remote.displayName = "Remote"
        ai.updateModel(remote, in: provider.id)
        #expect(throws: SettingsDraftMerge.Conflict.self) { try editor.save() }
        #expect(editor.draft.models[0].displayName == "Local")
        #expect(ai.modelProvider(provider.id)?.models[0].displayName == "Remote")
    }

    @Test func remoteModelDeletionCannotBeUndoneByEditingTheOldModel() {
        let provider = provider()
        let ai = AIConfigurationModel(modelProviders: [provider])
        let editor = MobileProviderEditorModel(ai: ai, provider: provider)
        editor.draft.models[0].displayName = "Local"
        ai.removeModels(["one"], from: provider.id)
        #expect(throws: SettingsDraftMerge.Conflict.self) { try editor.save() }
    }

    @Test func draftEndpointAndReplacementKeyAreUsedWithoutSaving() throws {
        let ai = AIConfigurationModel()
        let editor = MobileProviderEditorModel(ai: ai, provider: provider())
        #expect(!editor.hasExistingKey)
        #expect(editor.requiresKey)
        #expect(editor.keyAction == .replace)
        #expect(!editor.canSave)
        editor.endpoint.url = "https://draft.invalid/v1"
        editor.endpoint.apiType = .responses
        editor.secret = "draft-key"
        #expect(editor.requestProvider.inferenceURL == "https://draft.invalid/v1/responses")
        #expect(try editor.requestSecret() == "draft-key")
        #expect(ai.modelProviders.isEmpty)
        editor.keyAction = .clear
        #expect(try editor.requestSecret() == "")
    }

    @Test func discoveryAcceptsUnsavedProvidersAndDeduplicatesCandidates() async {
        let provider = provider()
        let discovery = MobileModelDiscovery(fetch: { request, secret in
            #expect(request.id == provider.id)
            #expect(secret == "draft")
            var named = AIModel(id: "new")
            named.displayName = "Research Chat Pro"
            return [AIModel(id: "one"), AIModel(id: "one"), named]
        })
        discovery.start(provider: provider, secret: "draft")
        while discovery.running { await Task.yield() }
        #expect(discovery.candidates.map(\.id) == ["one", "new"])
        #expect(discovery.candidates.last?.label == "Research Chat Pro")
        #expect(discovery.candidates.first?.label == "one")
    }

    @Test func batchTestsRunInOrderAndOnlyForExplicitTargets() async {
        let calls = ProbeCalls()
        let provider = provider()
        let probes = MobileModelTests(probe: { model, _, secret in
            #expect(secret == "draft")
            await calls.record(model.id)
            return model.id
        })
        probes.start(models: provider.models.reversed(), provider: provider, secret: "draft")
        while probes.running { await Task.yield() }
        #expect(await calls.ids == ["two", "one"])
        #expect(probes.results == ["one": "one", "two": "two"])
    }

    @Test func cancelledTestDropsLateResultsAndStopsRemainingBatch() async {
        let latch = AIRequestLatch<String>()
        let provider = provider()
        let probes = MobileModelTests(probe: { _, _, _ in await latch.wait() })
        probes.start(models: provider.models, provider: provider, secret: "")
        await latch.awaitStarted()
        probes.cancel()
        await latch.finish("late")
        for _ in 0..<20 { await Task.yield() }
        #expect(probes.results.isEmpty)
        #expect(!probes.running)
    }

    @Test func memoryFollowsMCPInAISettings() {
        #expect(MobileAISettingsDestination.allCases == [.models, .skills, .mcp, .memory])
    }

    @Test func skillsSaveAsDraftsThenLockNamesWithoutChangingRemoteFields() throws {
        let library = SkillLibraryModel()
        let new = MobileSkillEditorModel(library: library, skill: AgentSkill(name: ""))
        new.draft.title = "Disk Check"
        try new.save()
        var saved = try #require(library.skill(new.original.id))
        #expect(saved.name == "disk-check")
        #expect(library.enabledSkills == AgentSkillLibrary.builtIns)
        let editor = MobileSkillEditorModel(library: library, skill: saved)
        editor.draft.title = "A different title"
        editor.draft.body = "Read disk usage."
        saved.summary = "Remote description"
        library.applyRemoteSnapshot([saved])
        try editor.save()
        saved = try #require(library.skill(saved.id))
        #expect(saved.name == "disk-check")
        #expect(saved.summary == "Remote description")
        #expect(saved.body == "Read disk usage.")
    }

    @Test func oversizedAndRemotelyDeletedSkillsAreNotSaved() {
        let skill = AgentSkill(name: "test", summary: "s", body: "b")
        let library = SkillLibraryModel(skills: [skill])
        let editor = MobileSkillEditorModel(library: library, skill: skill)
        editor.draft.body = String(repeating: "x", count: AgentSkill.maximumBodyBytes + 1)
        #expect(!editor.canSave)
        editor.draft.body = "changed"
        library.delete(id: skill.id)
        #expect(throws: (any Error).self) { try editor.save() }
        #expect(library.skills.isEmpty)
    }

    @Test func mcpDiscoveryUsesDraftAndPreservesPermissionsUntilSave() async throws {
        var tool = MCPTool(id: "existing")
        tool.accessPolicy = .deny
        let server = MCPServer(name: "Gateway", namespaceID: "", url: "https://original.invalid/mcp", tools: [tool])
        let ai = AIConfigurationModel()
        let editor = MobileMCPEditorModel(
            ai: ai, server: server,
            discover: { request, token in
                #expect(request.url == "https://draft.invalid/mcp")
                #expect(token == "draft-token")
                return MCPDiscovery(
                    protocolVersion: "test", serverName: "Test",
                    tools: [
                        MCPTool(id: "existing"),
                        MCPTool(id: "new"),
                        MCPTool(
                            id: "read-only",
                            annotations: MCPToolAnnotations(readOnlyHint: true)
                        ),
                        MCPTool(
                            id: "conflicting",
                            annotations: MCPToolAnnotations(readOnlyHint: true, destructiveHint: true)
                        ),
                    ]
                )
            })
        editor.draft.url = "https://draft.invalid/mcp"
        editor.key.action = .replace
        editor.key.text = "draft-token"
        editor.connect()
        while editor.running { await Task.yield() }
        #expect(ai.mcpServers.isEmpty)
        #expect(editor.draft.tools.map(\.accessPolicy) == [.deny, .ask, .approve, .ask])
        let conflictingIndex = try #require(editor.draft.tools.firstIndex { $0.id == "conflicting" })
        editor.draft.tools[conflictingIndex].accessPolicy = .approve
        try editor.save()
        #expect(ai.mcpServer(server.id)?.namespaceID == "gateway")
        #expect(ai.mcpServer(server.id)?.tools.map(\.accessPolicy) == [.deny, .ask, .approve, .approve])
    }

    @Test func mcpCancellationAndRemoteDeletionCannotRestoreResults() async {
        let latch = AIRequestLatch<MCPDiscovery>()
        let server = MCPServer(name: "Test", url: "https://example.invalid/mcp")
        let ai = AIConfigurationModel()
        ai.upsert(server)
        let editor = MobileMCPEditorModel(ai: ai, server: server, discover: { _, _ in await latch.wait() })
        editor.connect()
        await latch.awaitStarted()
        editor.cancel()
        ai.delete(serverID: server.id)
        await latch.finish(MCPDiscovery(protocolVersion: "test", serverName: "late", tools: [MCPTool(id: "late")]))
        for _ in 0..<20 { await Task.yield() }
        #expect(editor.draft.tools.isEmpty)
        #expect(editor.connection == nil)
        #expect(throws: (any Error).self) { try editor.save() }
        #expect(ai.mcpServers.isEmpty)
    }

    @Test func enabledSwitchesOnlyCommitWithTheirEditors() throws {
        let provider = provider()
        let ai = AIConfigurationModel(modelProviders: [provider])
        let providerEditor = MobileProviderEditorModel(ai: ai, provider: provider)
        providerEditor.draft.isEnabled = false
        #expect(ai.modelProvider(provider.id)?.isEnabled == true)
        try providerEditor.save()
        #expect(ai.modelProvider(provider.id)?.isEnabled == false)

        let skill = AgentSkill(name: "test", summary: "s", body: "b")
        let skills = SkillLibraryModel(skills: [skill])
        let skillEditor = MobileSkillEditorModel(library: skills, skill: skill)
        skillEditor.draft.isEnabled = false
        #expect(skills.skill(skill.id)?.isEnabled == true)
        try skillEditor.save()
        #expect(skills.skill(skill.id)?.isEnabled == false)

        let server = MCPServer(name: "Test", url: "https://example.invalid/mcp")
        ai.upsert(server)
        let serverEditor = MobileMCPEditorModel(ai: ai, server: server)
        serverEditor.draft.isEnabled = false
        #expect(ai.mcpServer(server.id)?.isEnabled == true)
        try serverEditor.save()
        #expect(ai.mcpServer(server.id)?.isEnabled == false)
    }

    @Test func changedSecretsAreNotOverwrittenByAnOlderEditor() throws {
        var provider = provider()
        provider.credentialRef = "shared-key"
        let secrets = AIEditorTestSecrets()
        secrets.values["shared-key"] = "original"
        let ai = AIConfigurationModel(modelProviders: [provider], aiSecrets: secrets)
        let editor = MobileProviderEditorModel(ai: ai, provider: provider)
        editor.keyAction = .replace
        editor.secret = "local"
        secrets.values["shared-key"] = "remote"
        #expect(throws: SettingsDraftMerge.Conflict.self) { try editor.save() }
        #expect(secrets.values["shared-key"] == "remote")
        #expect(editor.secret == "local")
    }

    @Test func failedMCPSaveRestoresTokenAndKeepsDiscoveredDraft() {
        let server = MCPServer(name: "Test", url: "https://example.invalid/mcp", credentialRef: "token")
        let persistence = AIEditorTestPersistence(server: server)
        let secrets = AIEditorTestSecrets()
        secrets.values["token"] = "original"
        let ai = AIConfigurationModel(persistence: persistence, aiSecrets: secrets)
        let editor = MobileMCPEditorModel(ai: ai, server: server)
        editor.key.action = .replace
        editor.key.text = "replacement"
        editor.draft.tools = [MCPTool(id: "new")]
        persistence.fail = true
        #expect(throws: (any Error).self) { try editor.save() }
        #expect(secrets.values["token"] == "original")
        #expect(ai.mcpServer(server.id)?.tools.isEmpty == true)
        #expect(editor.draft.tools.map(\.id) == ["new"])
        #expect(editor.key.text == "replacement")
    }

    @Test func changingMCPConnectionClearsStaleToolsAndRejectsNonHTTPURLs() {
        let server = MCPServer(name: "Test", url: "https://example.invalid/mcp", tools: [MCPTool(id: "old")])
        let editor = MobileMCPEditorModel(ai: AIConfigurationModel(), server: server)
        editor.draft.url = "file:///tmp/example"
        editor.invalidateConnection()
        #expect(!editor.canSave)
        #expect(editor.draft.tools.isEmpty)
        #expect(editor.draft.lastConnectedAt == nil)
        editor.draft.url = "http://localhost:8080/mcp"
        #expect(editor.canSave)
    }

    @Test func mcpHeadersStayInTheServerDraftAndInvalidateDiscovery() throws {
        let header = MCPHeader(name: "X-Tenant", value: "original")
        var server = MCPServer(
            name: "Test", url: "https://example.invalid/mcp", headers: [header], tools: [MCPTool(id: "old")])
        server.negotiatedVersion = "test"
        server.lastConnectedAt = Date(timeIntervalSince1970: 1)
        let ai = AIConfigurationModel()
        ai.upsert(server)
        let editor = MobileMCPEditorModel(ai: ai, server: server)

        var edited = header
        edited.value = "draft"
        editor.upsertHeader(edited)

        #expect(ai.mcpServer(server.id)?.headers.first?.value == "original")
        #expect(editor.draft.headers.first?.value == "draft")
        #expect(editor.draft.tools.isEmpty)
        #expect(editor.draft.negotiatedVersion.isEmpty)
        #expect(editor.draft.lastConnectedAt == nil)

        try editor.save()
        #expect(ai.mcpServer(server.id)?.headers.first?.value == "draft")

        let removal = MobileMCPEditorModel(ai: ai, server: try #require(ai.mcpServer(server.id)))
        removal.removeHeaders(atOffsets: IndexSet(integer: 0))
        #expect(ai.mcpServer(server.id)?.headers.count == 1)
        try removal.save()
        #expect(ai.mcpServer(server.id)?.headers.isEmpty == true)
    }

    @Test func mcpNamespaceCollisionPreventsSaving() {
        let ai = AIConfigurationModel()
        ai.upsert(MCPServer(name: "Test", url: "https://example.invalid/mcp"))
        let editor = MobileMCPEditorModel(ai: ai, server: MCPServer(name: "Test", url: "https://other.invalid/mcp"))
        #expect(!editor.canSave)
    }

    @Test func mcpListStatusUsesConflictDisabledConnectionAndToolPriority() {
        var server = MCPServer(name: "Test", url: "https://example.invalid/mcp")
        #expect(MobileMCPServerStatus(server: server, hasNamespaceConflict: false) == .notConnected)

        server.isEnabled = false
        #expect(MobileMCPServerStatus(server: server, hasNamespaceConflict: false) == .disabled)
        #expect(MobileMCPServerStatus(server: server, hasNamespaceConflict: true) == .conflict)

        server.isEnabled = true
        server.lastConnectedAt = Date(timeIntervalSince1970: 1)
        let denied = MCPTool(id: "denied", accessPolicy: .deny)
        server.tools = [MCPTool(id: "active"), denied]
        #expect(
            MobileMCPServerStatus(server: server, hasNamespaceConflict: false)
                == .tools(count: 2))
    }
}

private actor ProbeCalls {
    var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}

private actor AIRequestLatch<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    func wait() async -> Value { await withCheckedContinuation { continuation = $0 } }
    func awaitStarted() async { while continuation == nil { await Task.yield() } }
    func finish(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor private final class AIEditorTestSecrets: AISecretStoring {
    var values: [String: String] = [:]
    func string(for reference: String) throws -> String? { values[reference] }
    func setString(_ value: String?, for reference: String) throws { values[reference] = value }
}

@MainActor private final class AIEditorTestPersistence: AIConfigurationPersisting {
    var snapshot: AIConfigurationSnapshot
    var fail = false
    init(server: MCPServer) { snapshot = .init(providers: [], roles: [:], mcpServers: [server]) }
    func load() throws -> AIConfigurationSnapshot { snapshot }
    func save(_ value: AIConfigurationSnapshot) throws {
        if fail { throw CocoaError(.fileWriteNoPermission) }
        snapshot = value
    }
}
