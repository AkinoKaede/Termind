// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import Testing

@Suite @MainActor
struct ModelProviderCredentialTests {
    @Test func anonymousProvidersIgnoreUnrelatedSecretFailuresWithoutReadingStorage() {
        let secrets = ProviderTestSecrets()
        secrets.failReads = true
        let ai = AIConfigurationModel(aiSecrets: secrets)
        #expect(ai.secret(for: "unavailable") == nil)
        #expect(ai.secretStorageError != nil)
        let provider = ModelProvider(name: "Anonymous", models: [AIModel(id: "test")])
        ai.upsert(provider)
        #expect(ai.modelSecret(for: provider) == "")
        #expect(CommandGeneratorController(ai: ai).isLocallyAvailable)
        #expect(secrets.reads == ["unavailable"])
        #expect(secrets.values.isEmpty)
    }

    @Test func configuredReferencesNeverFallBackToAnonymousRequests() {
        let secrets = ProviderTestSecrets()
        let ai = AIConfigurationModel(aiSecrets: secrets)
        let provider = ModelProvider(name: "Authenticated", credentialRef: "key", models: [AIModel(id: "test")])
        ai.upsert(provider)
        let command = CommandGeneratorController(ai: ai)
        #expect(ai.modelSecret(for: provider) == nil)
        #expect(!command.isLocallyAvailable)
        secrets.values["key"] = ""
        #expect(ai.modelSecret(for: provider) == nil)
        secrets.values["key"] = "test-key"
        #expect(ai.modelSecret(for: provider) == "test-key")
        #expect(command.isLocallyAvailable)
        secrets.failReads = true
        #expect(ai.modelSecret(for: provider) == nil)
        #expect(!command.isLocallyAvailable)
    }

    @Test func vertexResolvesOnlyItsServiceAccountCredential() {
        let secrets = ProviderTestSecrets()
        let ai = AIConfigurationModel(aiSecrets: secrets)
        var provider = ModelProvider(
            name: "Vertex", apiFormat: .generateContent, credentialRef: "ordinary", usesVertex: true)
        secrets.values["ordinary"] = "wrong-key"
        #expect(ai.modelSecret(for: provider) == nil)
        provider.vertex.projectID = "test-project"
        provider.vertex.credentialRef = "service-account"
        #expect(ai.modelSecret(for: provider) == nil)
        secrets.values["service-account"] = "service-account-json"
        #expect(ai.modelSecret(for: provider) == "service-account-json")
    }

    @Test func clearingAKeyEnablesAnonymousResolutionWithoutCreatingASecret() {
        let secrets = ProviderTestSecrets()
        let ai = AIConfigurationModel(aiSecrets: secrets)
        var provider = ModelProvider(name: "Gateway", credentialRef: "key")
        ai.setSecret("test-key", for: "key")
        #expect(ai.modelSecret(for: provider) == "test-key")
        ai.setSecret(nil, for: "key")
        #expect(ai.modelSecret(for: provider) == nil)
        provider.credentialRef = ""
        #expect(ai.modelSecret(for: provider) == "")
        #expect(secrets.values.isEmpty)
    }
}

@MainActor private final class ProviderTestSecrets: AISecretStoring {
    enum Failure: Error { case unavailable }
    var values: [String: String] = [:]
    var reads: [String] = []
    var failReads = false

    func string(for reference: String) throws -> String? {
        reads.append(reference)
        if failReads { throw Failure.unavailable }
        return values[reference]
    }

    func setString(_ value: String?, for reference: String) throws { values[reference] = value }
}
