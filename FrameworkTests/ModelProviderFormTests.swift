// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct ModelProviderFormTests {
    @Test(arguments: ModelAPIType.allCases)
    func emptyInputsSaveConcreteDefaultsWithoutChangingTheDraft(_ type: ModelAPIType) {
        let draft = ModelProvider(name: " \n")
        let endpoint = ProviderEndpoint(apiType: type, url: " \n")
        let ai = AIConfigurationModel(persistsSecrets: false)
        #expect(ai.saveProvider(draft, endpoint: endpoint))
        let stored = ai.modelProvider(draft.id)
        #expect(stored?.name == type.defaultProviderName)
        #expect(ai.endpoint(for: draft.id).url == type.defaultURL)
        #expect(stored?.inferenceURL == ProviderEndpoint(apiType: type, url: type.defaultURL).requestURL)
        #expect(endpoint.url == " \n")
        #expect(draft.name == " \n")
    }

    @Test func automaticUsesResponsesOnlyForAnEmptyFormURL() {
        let empty = ModelProviderForm.normalized(ModelProvider(name: ""), endpoint: .init())
        #expect(empty.provider.name == "OpenAI")
        #expect(empty.provider.apiFormat == .responses)
        #expect(empty.endpoint.url == "https://api.openai.com/v1/responses")
        #expect(empty.provider.resolvedModelsURL == "https://api.openai.com/v1/models")
        #expect(ProviderEndpoint().requestURL.isEmpty)
        #expect(ProviderEndpoint(url: "https://local.test/v1").format == .chatCompletions)
    }

    @Test func explicitValuesAreNeverReplacedEvenWhenTheyMatchAnotherDefault() {
        let value = ModelProviderForm.normalized(
            ModelProvider(name: "OpenAI"),
            endpoint: .init(apiType: .messages, url: ModelAPIType.automatic.defaultURL))
        #expect(value.provider.name == "OpenAI")
        #expect(value.provider.apiFormat == .messages)
        #expect(value.endpoint.url == ModelAPIType.automatic.defaultURL)
        let bad = ModelProviderForm.normalized(ModelProvider(name: "Private"), endpoint: .init(url: "bad URL"))
        #expect(!ModelProviderForm.hasValidAddress(bad.provider))
        #expect(bad.endpoint.url == "bad URL")
    }

    @Test func vertexNormalizesLocationAndKeepsItsSeparateDestination() {
        var provider = ModelProvider(name: "", usesVertex: true)
        provider.vertex = VertexConfig(projectID: "project", location: " ", credentialRef: "account")
        let value = ModelProviderForm.normalized(provider, endpoint: .init(apiType: .generateContent))
        #expect(value.provider.name == "Google")
        #expect(value.provider.vertex.location == "global")
        #expect(ModelProviderForm.hasValidAddress(value.provider))
        #expect(
            value.provider.requestURL()
                == "https://aiplatform.googleapis.com/v1/projects/project/locations/global/publishers/google/models/{model}:generateContent"
        )
        #expect(!value.provider.canFetchModels)
        let switched = ModelProviderForm.normalized(provider, endpoint: .init(apiType: .messages)).provider
        #expect(!switched.usesVertex)
        #expect(switched.vertex.credentialRef == "account")
        provider.vertex.projectID = "project/escape"
        #expect(
            !ModelProviderForm.hasValidAddress(
                ModelProviderForm.normalized(provider, endpoint: .init(apiType: .generateContent)).provider))
    }
}
