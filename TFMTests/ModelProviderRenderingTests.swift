import AgentKit
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite(.serialized) @MainActor
struct ModelProviderRenderingTests {
    @Test func newEditorKeepsEmptyBuffersWhileReopeningReadsSavedDefaults() throws {
        let ai = AIConfigurationModel(persistsSecrets: false)
        let provider = ModelProvider(name: "")
        #expect(ai.saveProvider(provider, endpoint: .init()))
        let saved = try #require(ai.modelProvider(provider.id))
        let newSession = ModelProviderEditorSession()
        newSession.begin(with: saved, in: ai, isNew: true)
        #expect(newSession.name.isEmpty)
        #expect(newSession.endpoint.url.isEmpty)
        let reopened = ModelProviderEditorSession()
        reopened.begin(with: saved, in: ai)
        #expect(reopened.name == "OpenAI")
        #expect(reopened.endpoint.url == ModelAPIType.automatic.defaultURL)
        #expect(!SettingsDraftPolicy.shouldDiscard(saved))
    }

    @Test func modelAutosaveKeepsTheEmptyInputAndReopeningShowsTheSavedName() throws {
        let first = AIModel(id: "first", displayName: "Custom")
        let second = AIModel(id: "second", displayName: "Catalog Name")
        let provider = ModelProvider(name: "Gateway", models: [first, second])
        let ai = AIConfigurationModel(modelProviders: [provider], persistsSecrets: false)
        let session = ModelNameEditorSession()
        session.begin(with: first)
        session.save("", model: first, providerID: provider.id, in: ai)
        #expect(session.name == "")
        #expect(ai.modelProvider(provider.id)?.model(first.id)?.displayName == first.id)
        session.begin(with: ai.modelProvider(provider.id)?.model(first.id))
        #expect(session.name == "")
        session.save("Renamed", model: first, providerID: provider.id, in: ai)
        #expect(ai.modelProvider(provider.id)?.model(first.id)?.displayName == "Renamed")
        session.save(" \t", model: first, providerID: provider.id, in: ai)
        #expect(session.name == " \t")
        session.begin(with: second)
        #expect(session.name == "Catalog Name")
        session.begin(with: ai.modelProvider(provider.id)?.model(first.id))
        #expect(session.name == first.id)
        let reopened = ModelNameEditorSession()
        reopened.begin(with: ai.modelProvider(provider.id)?.model(first.id))
        #expect(reopened.name == first.id)
    }

}
