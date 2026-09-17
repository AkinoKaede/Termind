import AgentKit
import Foundation
import Security
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import Testing

@Suite @MainActor
struct ModelProviderVertexTests {
    private func vertexProvider() -> ModelProvider {
        ModelProvider(
            name: "Google", apiFormat: .generateContent, credentialRef: "api-key", usesVertex: true,
            vertex: VertexConfig(
                projectID: "test-project", location: "us-central1", credentialRef: "service-account",
                clientEmail: "fixture@example.invalid"), models: [AIModel(id: "gemini-test")])
    }

    @Test func vertexPersistsAlongsideTheFrozenProviderRowAndDeletesWithIt() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let persistence = AIPersistence(context: container.mainContext)
        let ai = AIConfigurationModel(persistence: persistence, persistsSecrets: false)
        let provider = vertexProvider()
        #expect(ai.saveProvider(provider, endpoint: .init(apiType: .generateContent)))
        let reopened = AIConfigurationModel(persistence: persistence, persistsSecrets: false)
        let saved = try #require(reopened.modelProvider(provider.id))
        #expect(saved.usesVertex)
        #expect(saved.vertex == provider.vertex)
        #expect(saved.models == provider.models)
        #expect(saved.requestURL().hasPrefix("https://us-central1-aiplatform.googleapis.com/"))
        #expect(reopened.endpoint(for: provider.id).url == ModelAPIType.generateContent.defaultURL)
        reopened.delete(modelProviderID: provider.id)
        #expect(try container.mainContext.fetch(FetchDescriptor<PersistentModelProviderVertexConfiguration>()).isEmpty)
    }

    @Test func v18MigratesWithoutChangingExistingProviderData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Store.sqlite")
        let schema = Schema(versionedSchema: TermindSchemaV18.self)
        let provider = ModelProvider(name: "Legacy", models: [AIModel(id: "private")])
        let endpoint = ProviderEndpoint(apiType: .messages, url: "https://private.invalid/v1")
        do {
            let legacy = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)
                ])
            legacy.mainContext.insert(PersistentModelProvider(provider, endpoint: endpoint, sortIndex: 0))
            legacy.mainContext.insert(PersistentAIModel(provider.models[0], providerID: provider.id, sortIndex: 0))
            try legacy.mainContext.save()
        }
        let container = try TermindPersistence.makeContainer(url: url)
        let snapshot = try AIPersistence(context: container.mainContext).load()
        #expect(snapshot.providers.first?.name == "Legacy")
        #expect(snapshot.providers.first?.models == provider.models)
        #expect(snapshot.endpoints[provider.id] == endpoint)
        #expect(snapshot.providers.first?.usesVertex == false)
    }

    @Test func syncRoundTripsVertexAndPreservesItWhenAnOlderWriterOmitsIt() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let defaults = UserDefaults(suiteName: "ProviderVertexTests.\(UUID())")!
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try store.prepare()
        let provider = vertexProvider()
        let endpoint = ProviderEndpoint(apiType: .generateContent, url: ModelAPIType.generateContent.defaultURL)
        var value = SyncedModelProvider(provider, endpoint: endpoint, sortIndex: 0)
        func envelope(_ value: SyncedModelProvider, time: TimeInterval) -> SettingsEnvelope {
            let payload = SettingsRecordPayload.provider(value)
            return SettingsEnvelope(
                key: payload.key,
                version: .next(after: nil, writerID: UUID(), now: Date(timeIntervalSinceNow: time)), payload: payload)
        }
        let first = envelope(value, time: 10)
        let roundTrip = try JSONDecoder().decode(SettingsEnvelope.self, from: JSONEncoder().encode(first))
        #expect(roundTrip == first)
        let received = try store.applyRemote([roundTrip]).snapshot.configuration.providers[0]
        #expect(received.vertex == provider.vertex)
        #expect(received.usesVertex)
        value.name = "Old client rename"
        value.vertex = nil
        let legacyData = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(SyncedModelProvider.self, from: legacyData).vertex == nil)
        let legacy = try store.applyRemote([envelope(value, time: 20)])
        #expect(legacy.snapshot.configuration.providers[0].name == "Old client rename")
        #expect(legacy.snapshot.configuration.providers[0].vertex == provider.vertex)
        #expect(legacy.snapshot.configuration.providers[0].usesVertex)
        #expect(legacy.needsUpload.contains(first.key))
        value.vertex = SyncedProviderVertex(provider)
        value.vertex?.isEnabled = false
        value.vertex?.credentialRef = ""
        let cleared = try store.applyRemote([envelope(value, time: 30)]).snapshot.configuration.providers[0]
        #expect(!cleared.usesVertex)
        #expect(cleared.vertex.credentialRef.isEmpty)
    }

    @Test func failedMetadataSaveRollsBackBothCredentialsAndKeepsDraftSecrets() throws {
        let provider = vertexProvider()
        let secrets = VertexSecrets()
        secrets.values = ["api-key": "old-key", "service-account": "old-json"]
        let persistence = FailingProviderPersistence(provider: provider)
        let ai = AIConfigurationModel(persistence: persistence, aiSecrets: secrets)
        let edits: [ModelProviderCredentialEdit] = [
            .init(kind: .apiKey, reference: "api-key", previous: "old-key", replacement: "new-key"),
            .init(kind: .serviceAccount, reference: "service-account", previous: "old-json", replacement: "new-json"),
        ]
        #expect(throws: (any Error).self) {
            try ai.saveProvider(provider, endpoint: .init(apiType: .generateContent), credentials: edits)
        }
        #expect(secrets.values == ["api-key": "old-key", "service-account": "old-json"])
        #expect(ai.modelProvider(provider.id) == provider)
        #expect(edits[1].replacement == "new-json")
    }

    @Test func credentialConflictsFailBeforeWritingAndDeletionCleansBothReferences() throws {
        let provider = vertexProvider()
        let secrets = VertexSecrets()
        secrets.values = ["api-key": "key", "service-account": "newer-json"]
        let ai = AIConfigurationModel(modelProviders: [provider], aiSecrets: secrets)
        #expect(throws: SettingsDraftMerge.Conflict.self) {
            try ai.saveProvider(
                provider, endpoint: .init(apiType: .generateContent),
                credentials: [
                    .init(
                        kind: .serviceAccount, reference: "service-account", previous: "old-json", replacement: "stale")
                ])
        }
        #expect(secrets.writes.isEmpty)
        ai.delete(modelProviderID: provider.id)
        #expect(secrets.values.isEmpty)
        #expect(Set(secrets.writes) == ["api-key", "service-account"])
    }

    @Test func fileAndPastedAccountsShareValidationAndRejectUntrustedTokenHosts() async throws {
        // Ephemeral test-only key: never written to the repository, Keychain, or a real Google account.
        let key = try #require(
            SecKeyCreateRandomKey(
                [
                    kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 1024,
                ] as CFDictionary, nil))
        let rsa = try #require(SecKeyCopyExternalRepresentation(key, nil)) as Data
        func der(_ tag: UInt8, _ data: Data) -> Data {
            let length = data.count
            return Data([tag, 0x82, UInt8(length >> 8), UInt8(length & 255)]) + data
        }
        let algorithm = Data([
            0x02, 0x01, 0x00, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7,
            0x0d, 0x01, 0x01, 0x01, 0x05, 0x00,
        ])
        let pem =
            "-----BEGIN PRIVATE KEY-----\n" + der(0x30, algorithm + der(0x04, rsa)).base64EncodedString()
            + "\n-----END PRIVATE KEY-----\n"
        let object = [
            "type": "service_account", "project_id": "test-project", "client_email": "fixture@example.invalid",
            "private_key": pem, "token_uri": "https://oauth2.googleapis.com/token",
        ]
        let json = String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
        let account = try ModelProviderServiceAccount(json: json)
        #expect(account.projectID == "test-project")
        #expect(account.clientEmail == "fixture@example.invalid")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.json")
        try Data(json.utf8).write(to: url)
        #expect(try await ModelProviderServiceAccountFile.read(url) == account.json)
        #expect(throws: (any Error).self) {
            try ModelProviderServiceAccount(
                json: json.replacingOccurrences(of: "oauth2.googleapis.com", with: "evil.invalid"))
        }
        try Data(repeating: 32, count: ModelProviderServiceAccount.maximumBytes + 1).write(to: url)
        await #expect(throws: (any Error).self) { try await ModelProviderServiceAccountFile.read(url) }
    }

    @Test func clearingAnUncommittedCredentialDoesNotMintAKeychainReference() throws {
        let secrets = VertexSecrets()
        let ai = AIConfigurationModel(aiSecrets: secrets)
        let provider = ModelProvider(name: "")
        try ai.saveProvider(
            provider, endpoint: .init(),
            credentials: [
                .init(kind: .serviceAccount, reference: "", previous: nil, replacement: nil)
            ])
        #expect(secrets.writes.isEmpty)
        #expect(ai.modelProvider(provider.id)?.vertex.credentialRef == "")
        #expect(ai.modelProvider(provider.id)?.name == "OpenAI")
    }

    @Test func failedCredentialCleanupRemainsVisibleAfterTheOtherReferenceSucceeds() {
        let provider = vertexProvider()
        let secrets = VertexSecrets()
        secrets.values = ["api-key": "key", "service-account": "json"]
        secrets.failingReference = "service-account"
        let ai = AIConfigurationModel(modelProviders: [provider], aiSecrets: secrets)
        ai.delete(modelProviderID: provider.id)
        #expect(ai.modelProvider(provider.id) == nil)
        #expect(secrets.values["api-key"] == nil)
        #expect(secrets.values["service-account"] == "json")
        #expect(ai.secretStorageError != nil)
        #expect(Set(secrets.writes) == ["api-key", "service-account"])
    }

    @Test func invalidServiceAccountErrorsNeverEchoInput() {
        for json in ["private-secret", "{}", String(repeating: "private-secret", count: 100_000)] {
            do {
                _ = try ModelProviderServiceAccount(json: json)
                Issue.record("Invalid service account accepted")
            } catch {
                #expect(!error.localizedDescription.contains("private-secret"))
            }
        }
    }
}

@MainActor private final class VertexSecrets: AISecretStoring {
    var values: [String: String] = [:]
    var writes: [String] = []
    var failingReference: String?
    enum Failure: Error { case inaccessible }
    func string(for reference: String) throws -> String? { values[reference] }
    func setString(_ value: String?, for reference: String) throws {
        writes.append(reference)
        if reference == failingReference { throw Failure.inaccessible }
        values[reference] = value
    }
}

@MainActor private final class FailingProviderPersistence: AIConfigurationPersisting {
    let provider: ModelProvider
    init(provider: ModelProvider) { self.provider = provider }
    func load() throws -> AIConfigurationSnapshot { .init(providers: [provider], roles: [:]) }
    func save(_ snapshot: AIConfigurationSnapshot) throws { throw Failure.failed }
    enum Failure: Error { case failed }
}
