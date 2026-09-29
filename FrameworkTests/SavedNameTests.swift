import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct SavedNameTests {
    @Test func missingInputsDoNotInventNameHints() {
        #expect(Host(name: "", host: " \n").defaultName == "")
        #expect(Identity(name: "", username: " \n").defaultName == "")
        #expect(AIModel(id: "").savingName.displayName == "")
        let forwarding = PortForwardingRule(hostID: UUID())
        #expect(forwarding.defaultName(hostName: "") == "")
        #expect(forwarding.defaultName(hostName: " \n") == "")
    }

    @Test(arguments: ["", " \t\n", "Production"])
    func vaultNamesMaterializeOnlyOnSaveAndSurviveReload(_ name: String) throws {
        let host = Host(name: name, host: "example.invalid")
        let identity = Identity(name: name, username: "deploy")
        let key = SSHKeyRef(label: name, algorithm: .rsa)
        let original = VaultSnapshot(hosts: [host], identities: [identity], keys: [key])
        let persistence = NameVaultPersistence(original)
        let library = HostLibraryModel(persistence: persistence)
        #expect(library.host(host.id)?.name == name)
        #expect(library.identity(identity.id)?.name == name)
        #expect(library.key(key.id)?.label == name)
        #expect(persistence.writes == 0)
        library.replacePersistedSnapshot(original)
        #expect(persistence.writes == 0)

        #expect(library.saveHost(host))
        try library.upsert(identity, passwordUpdate: .keep)
        try library.upsert(key)
        let reopened = HostLibraryModel(persistence: persistence)
        let isBlank = name != "Production"
        #expect(reopened.host(host.id)?.name == (isBlank ? "example.invalid" : name))
        #expect(reopened.identity(identity.id)?.name == (isBlank ? "deploy" : name))
        #expect(reopened.key(key.id)?.label == (isBlank ? "RSA" : name))
        #expect(persistence.writes == 3)
    }

    @Test func storedDefaultsAreOrdinaryNamesUntilExplicitlyCleared() throws {
        let library = HostLibraryModel()
        let host = Host(name: "", host: "first.invalid")
        #expect(library.saveHost(host))
        var savedHost = try #require(library.host(host.id))
        savedHost.host = "second.invalid"
        #expect(library.saveHost(savedHost))
        #expect(library.host(host.id)?.name == "first.invalid")
        savedHost.name = " \n"
        #expect(library.saveHost(savedHost))
        #expect(library.host(host.id)?.name == "second.invalid")

        let identity = Identity(name: "", username: "deploy")
        #expect(library.upsert(identity))
        var savedIdentity = try #require(library.identity(identity.id))
        savedIdentity.username = "root"
        #expect(library.upsert(savedIdentity))
        #expect(library.identity(identity.id)?.name == "deploy")
        savedIdentity.name = ""
        #expect(library.upsert(savedIdentity))
        #expect(library.identity(identity.id)?.name == "root")

        let key = SSHKeyRef(label: "", algorithm: .ed25519)
        try library.upsert(key)
        var savedKey = try #require(library.key(key.id))
        savedKey.algorithm = .rsa
        try library.upsert(savedKey)
        #expect(library.key(key.id)?.label == "Ed25519")
        savedKey.label = ""
        try library.upsert(savedKey)
        #expect(library.key(key.id)?.label == "RSA")
    }

    @Test(arguments: SSHKeyAlgorithm.allCases, KeyStorage.allCases)
    func keyHintsMatchPersistedAlgorithmAndStorageDefaults(_ algorithm: SSHKeyAlgorithm, _ storage: KeyStorage) throws {
        let library = HostLibraryModel()
        if algorithm == .securityKey, storage == .secureEnclave { return }
        if algorithm != .securityKey, storage == .external { return }
        var key = SSHKeyRef(label: " \n", algorithm: algorithm, storage: storage)
        if algorithm == .securityKey {
            key.securityKey = SecurityKeyCredential(
                credentialID: Data([1]), publicKeyX963: Data([4]) + Data(repeating: 1, count: 64))
        }
        try library.upsert(key)
        #expect(library.key(key.id)?.label == key.defaultName)
        if algorithm == .securityKey, storage != .secureEnclave {
            #expect(library.key(key.id)?.label == "Security Key")
        }
        #expect(key.defaultName == (storage == .secureEnclave ? "Secure Enclave" : algorithm.typeName))
    }

    @Test(arguments: PortForwardingRule.Kind.allCases)
    func forwardingSaveReturnsTheConcreteDraftAndKeepsItsNameWhenTheHostChanges(_ kind: PortForwardingRule.Kind) throws
    {
        var host = Host(name: "AWS", host: "example.invalid")
        let persistence = NameVaultPersistence(.init(hosts: [host]))
        let library = HostLibraryModel(persistence: persistence)
        let forwardings = ForwardingLibraryModel(library: library)
        let draft = PortForwardingRule(hostID: host.id, kind: kind, label: " \n")
        let saved = try forwardings.save(draft)
        #expect(saved.label == draft.defaultName(hostName: "AWS"))
        #expect(PortForwardingEditorPolicy.normalized(saved) == library.portForwarding(saved.id))
        host.name = "Renamed"
        #expect(library.saveHost(host))
        var changed = saved
        changed.kind = .dynamic
        let resaved = try forwardings.save(changed)
        #expect(resaved.label == saved.label)
        #expect(HostLibraryModel(persistence: persistence).portForwarding(saved.id)?.label == saved.label)
        changed.label = ""
        #expect(try forwardings.save(changed).label == "Renamed (-D)")
    }

    @Test func failedVaultSavesKeepLegacyNamesAndTheStoredSnapshot() throws {
        let host = Host(name: "", host: "example.invalid")
        let identity = Identity(name: "", username: "deploy")
        let key = SSHKeyRef(label: "")
        let rule = PortForwardingRule(hostID: host.id)
        let original = VaultSnapshot(hosts: [host], identities: [identity], keys: [key], portForwardings: [rule])
        let persistence = NameVaultPersistence(original)
        let library = HostLibraryModel(persistence: persistence)
        persistence.fails = true
        #expect(!library.saveHost(host))
        #expect(!library.upsert(identity))
        #expect(throws: (any Error).self) { try library.upsert(identity, passwordUpdate: .keep) }
        #expect(throws: (any Error).self) { try library.upsert(key) }
        #expect(throws: (any Error).self) { try ForwardingLibraryModel(library: library).save(rule) }
        #expect(library.host(host.id)?.name == "")
        #expect(library.identity(identity.id)?.name == "")
        #expect(library.key(key.id)?.label == "")
        #expect(library.portForwarding(rule.id)?.label == "")
        #expect(persistence.writes == 0)
        #expect(persistence.snapshot.hosts == original.hosts)
        #expect(persistence.snapshot.identities == original.identities)
        #expect(persistence.snapshot.keys == original.keys)
        #expect(persistence.snapshot.portForwardings == original.portForwardings)
        persistence.fails = false
        #expect(try ForwardingLibraryModel(library: library).save(rule).label == "example.invalid (-L)")
    }

    @Test func providerAndModelNamesRoundTripWithoutBackfillingReadsOrFailedWrites() throws {
        let provider = ModelProvider(name: " \n", models: [AIModel(id: "private-model", displayName: " \n")])
        let snapshot = AIConfigurationSnapshot(providers: [provider], roles: [:])
        let persistence = NameAIPersistence(snapshot)
        let ai = AIConfigurationModel(persistence: persistence, persistsSecrets: false)
        ai.applyRemoteSnapshot(snapshot, webSearch: .init())
        #expect(ai.modelProviders == [provider])
        #expect(persistence.writes == 0)
        persistence.fails = true
        #expect(!ai.saveProvider(provider, endpoint: .init(apiType: .messages)))
        #expect(ai.modelProviders == [provider])
        #expect(persistence.writes == 0)
        persistence.fails = false
        #expect(ai.saveProvider(provider, endpoint: .init(apiType: .messages)))
        let reloaded = AIConfigurationModel(persistence: persistence, persistsSecrets: false)
        let saved = try #require(reloaded.modelProvider(provider.id))
        #expect(saved.name == "Anthropic")
        #expect(saved.models.first?.displayName == "private-model")
        reloaded.setEndpoint(.init(apiType: .generateContent), for: saved.id)
        #expect(reloaded.modelProvider(saved.id)?.name == "Anthropic")
    }

    @Test func modelWritesFreezeDefaultsAndCatalogRefreshPreservesNames() throws {
        let provider = ModelProvider(name: "Gateway")
        let ai = AIConfigurationModel(modelProviders: [provider], persistsSecrets: false)
        ai.addModel(AIModel(id: "manual", displayName: " \n"), to: provider.id)
        ai.addModel(AIModel(id: "fetched", displayName: "Catalog Name", origin: .fetched), to: provider.id)
        #expect(ai.modelProvider(provider.id)?.model("manual")?.displayName == "manual")
        ai.replaceModels(
            [
                AIModel(id: "manual", displayName: "Future Catalog Name", contextLength: 42),
                AIModel(id: "fetched", displayName: "Changed Catalog Name"),
                AIModel(id: "new", displayName: ""),
            ], for: provider.id)
        #expect(ai.modelProvider(provider.id)?.model("manual")?.displayName == "manual")
        #expect(ai.modelProvider(provider.id)?.model("manual")?.contextLength == 42)
        #expect(ai.modelProvider(provider.id)?.model("fetched")?.displayName == "Catalog Name")
        #expect(ai.modelProvider(provider.id)?.model("new")?.displayName == "new")
        var edited = try #require(ai.modelProvider(provider.id)?.model("fetched"))
        edited.displayName = "Custom"
        ai.updateModel(edited, in: provider.id)
        #expect(ai.modelProvider(provider.id)?.model("fetched")?.displayName == "Custom")
        edited.displayName = " \t"
        ai.updateModel(edited, in: provider.id)
        #expect(ai.modelProvider(provider.id)?.model("fetched")?.displayName == "fetched")
    }
}

@MainActor
private final class NameVaultPersistence: VaultPersisting {
    var snapshot: VaultSnapshot
    var writes = 0
    var fails = false
    init(_ snapshot: VaultSnapshot) { self.snapshot = snapshot }
    func load() throws -> VaultSnapshot { snapshot }
    func save(
        _ snapshot: VaultSnapshot, touching keys: Set<VaultRecordKey>
    ) throws -> VaultMutationSet {
        if fails { throw CocoaError(.fileWriteUnknown) }
        self.snapshot = snapshot
        writes += 1
        return .empty
    }
    func applyRemote(_ envelopes: [VaultEnvelope]) throws -> VaultRemoteApplyResult {
        VaultRemoteApplyResult(snapshot: snapshot, acceptedKeys: [], needsUpload: [])
    }
}

@MainActor
private final class NameAIPersistence: AIConfigurationPersisting {
    var snapshot: AIConfigurationSnapshot
    var writes = 0
    var fails = false
    init(_ snapshot: AIConfigurationSnapshot) { self.snapshot = snapshot }
    func load() throws -> AIConfigurationSnapshot { snapshot }
    func save(_ snapshot: AIConfigurationSnapshot) throws {
        if fails { throw CocoaError(.fileWriteUnknown) }
        self.snapshot = snapshot
        writes += 1
    }
}
