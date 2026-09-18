import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileProviderDefaultsTests {
    @Test(arguments: ModelAPIType.allCases)
    func blankDraftsPreviewDefaultsAndPersistConcreteValues(_ type: ModelAPIType) throws {
        let ai = AIConfigurationModel(persistsSecrets: false)
        let editor = MobileProviderEditorModel(ai: ai, provider: ModelProvider(name: ""))
        #expect(!editor.isDirty)
        editor.endpoint.apiType = type
        #expect(editor.canSave)
        #expect(editor.draft.name.isEmpty)
        #expect(editor.endpoint.url.isEmpty)
        #expect(editor.requestProvider.name == type.defaultProviderName)
        #expect(try editor.requestSecret() == "")
        #expect(ai.modelProviders.isEmpty)
        try editor.save()
        let saved = try #require(ai.modelProvider(editor.original.id))
        #expect(saved.name == type.defaultProviderName)
        #expect(ai.endpoint(for: saved.id).url == type.defaultURL)
        let reopened = MobileProviderEditorModel(ai: ai, provider: saved)
        #expect(reopened.draft.name == type.defaultProviderName)
        #expect(reopened.endpoint.url == type.defaultURL)
        #expect(!reopened.isDirty)
    }

    @Test func typeSwitchDoesNotReplaceExplicitValuesAndDefaultsUseMergedType() throws {
        let ai = AIConfigurationModel(persistsSecrets: false)
        let provider = ModelProvider(name: "Original")
        #expect(ai.saveProvider(provider, endpoint: .init()))
        let saved = try #require(ai.modelProvider(provider.id))
        let editor = MobileProviderEditorModel(ai: ai, provider: saved)
        editor.draft.name = ""
        editor.endpoint.url = ""
        ai.setEndpoint(.init(apiType: .messages, url: ModelAPIType.automatic.defaultURL), for: provider.id)
        try editor.save()
        #expect(ai.modelProvider(provider.id)?.name == "Anthropic")
        #expect(ai.endpoint(for: provider.id).url == ModelAPIType.messages.defaultURL)
        let explicit = MobileProviderEditorModel(ai: ai, provider: try #require(ai.modelProvider(provider.id)))
        explicit.endpoint.apiType = .generateContent
        #expect(explicit.draft.name == "Anthropic")
        #expect(explicit.endpoint.url == ModelAPIType.messages.defaultURL)
    }

    @Test func modelNamesAreMaterializedAfterMergingTheProviderDraft() throws {
        let model = AIModel(id: "private-model", displayName: "Original")
        let provider = ModelProvider(name: "Gateway", models: [model])
        let ai = AIConfigurationModel(modelProviders: [provider], persistsSecrets: false)
        let editor = MobileProviderEditorModel(ai: ai, provider: provider)
        editor.draft.models[0].displayName = " \n"
        var remote = model
        remote.contextLength = 1234
        ai.updateModel(remote, in: provider.id)
        try editor.save()
        let saved = try #require(ai.modelProvider(provider.id))
        #expect(saved.models[0].displayName == model.id)
        #expect(saved.models[0].contextLength == 1234)
        let reopened = MobileProviderEditorModel(ai: ai, provider: saved)
        #expect(reopened.draft.models[0].displayName == model.id)
        #expect(!reopened.isDirty)
        let conflict = MobileProviderEditorModel(ai: ai, provider: saved)
        conflict.draft.models[0].displayName = ""
        remote = saved.models[0]
        remote.displayName = "Remote Name"
        ai.updateModel(remote, in: provider.id)
        #expect(throws: SettingsDraftMerge.Conflict.self) { try conflict.save() }
        #expect(conflict.draft.models[0].displayName == "")
        #expect(ai.modelProvider(provider.id)?.models[0].displayName == "Remote Name")
    }

    @Test(arguments: ["", " \n"], ["", "Local Name"])
    func legacyNameMaterializationDoesNotConflictWithDraftEdits(originalName: String, localName: String) throws {
        let model = AIModel(id: "private-model", displayName: originalName)
        let provider = ModelProvider(name: "Gateway", models: [model])
        let ai = AIConfigurationModel(modelProviders: [provider], persistsSecrets: false)
        let editor = MobileProviderEditorModel(ai: ai, provider: provider)
        if !localName.isEmpty { editor.draft.models[0].displayName = localName }
        editor.draft.models[0].maxOutputTokens = 512
        var remote = model
        remote.contextLength = 1234
        ai.updateModel(remote, in: provider.id)
        #expect(ai.modelProvider(provider.id)?.models[0].displayName == model.id)

        try editor.save()

        let saved = try #require(ai.modelProvider(provider.id)?.models.first)
        #expect(saved.displayName == (localName.isEmpty ? model.id : localName))
        #expect(saved.contextLength == 1234)
        #expect(saved.maxOutputTokens == 512)
    }

    @Test(arguments: ["private-model", "Custom Name"], ["", " \n"])
    func clearingASavedNameConflictsWithARemoteRename(originalName: String, clearedName: String) throws {
        let model = AIModel(id: "private-model", displayName: originalName)
        let provider = ModelProvider(name: "Gateway", models: [model])
        let ai = AIConfigurationModel(modelProviders: [provider], persistsSecrets: false)
        let editor = MobileProviderEditorModel(ai: ai, provider: provider)
        editor.draft.models[0].displayName = clearedName
        var remote = model
        remote.displayName = "Remote Name"
        ai.updateModel(remote, in: provider.id)

        #expect(throws: SettingsDraftMerge.Conflict.self) { try editor.save() }
        #expect(editor.draft.models[0].displayName == clearedName)
        #expect(ai.modelProvider(provider.id)?.models[0] == remote)
    }

    @Test func vertexPreviewSelectsItsOwnCredentialAndCanSaveAfterClearingIt() throws {
        let ai = AIConfigurationModel(persistsSecrets: false)
        let provider = ModelProvider(name: "Google", credentialRef: "key")
        #expect(ai.saveProvider(provider, endpoint: .init(apiType: .generateContent)))
        ai.setSecret("ordinary-key", for: "key")
        let editor = MobileProviderEditorModel(ai: ai, provider: try #require(ai.modelProvider(provider.id)))
        editor.draft.usesVertex = true
        #expect(!editor.canSave)
        editor.draft.vertex.projectID = "project"
        editor.draft.vertex.location = ""
        #expect(editor.canSave)
        #expect(throws: (any Error).self) { try editor.requestSecret() }
        editor.serviceAccount.action = .replace
        editor.serviceAccount.text = "draft-service-account-json"
        editor.draft.vertex.clientEmail = "fixture@example.invalid"
        #expect(try editor.requestSecret() == "draft-service-account-json")
        #expect(ai.modelProvider(provider.id)?.usesVertex == false)
        try editor.save()
        let saved = try #require(ai.modelProvider(provider.id))
        #expect(saved.vertex.location == "global")
        #expect(saved.credentialRef == "key")
        #expect(!saved.vertex.credentialRef.isEmpty)
        #expect(ai.modelSecret(for: saved) == "draft-service-account-json")
        let reopened = MobileProviderEditorModel(ai: ai, provider: saved)
        reopened.removeServiceAccount()
        #expect(reopened.canSave)
        #expect(throws: (any Error).self) { try reopened.requestSecret() }
        try reopened.save()
        #expect(ai.modelProvider(provider.id)?.vertex.credentialRef == "")
        #expect(ai.secret(for: saved.vertex.credentialRef) == nil)
        #expect(ai.secret(for: "key") == "ordinary-key")
    }

    @Test func vertexProjectConflictsRejectSaveAndInvalidImportsDoNotAlterDraft() throws {
        let ai = AIConfigurationModel(persistsSecrets: false)
        let provider = ModelProvider(
            name: "Google", usesVertex: true,
            vertex: VertexConfig(projectID: "original", credentialRef: "service"))
        #expect(ai.saveProvider(provider, endpoint: .init(apiType: .generateContent)))
        let saved = try #require(ai.modelProvider(provider.id))
        let editor = MobileProviderEditorModel(ai: ai, provider: saved)
        #expect(throws: (any Error).self) { try editor.importServiceAccount("private-invalid") }
        #expect(editor.draft == saved)
        editor.draft.vertex.projectID = "local"
        var remote = saved
        remote.vertex.projectID = "remote"
        ai.upsert(remote)
        #expect(throws: SettingsDraftMerge.Conflict.self) { try editor.save() }
        #expect(ai.modelProvider(provider.id)?.vertex.projectID == "remote")
    }
}
