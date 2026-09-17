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
