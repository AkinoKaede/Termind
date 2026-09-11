import AgentKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import TermindRemoteInfrastructure
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileSettingsPortTests {
    @Test func sftpSettingsDefaultsAndNormalizationMatchDesktop() {
        #expect(SettingsKey.sftpGlobalTransferLimit == "sftp.transfers.globalLimit")
        #expect(SettingsKey.sftpPerHostTransferLimit == "sftp.transfers.perHostLimit")
        #expect(SettingsKey.defaultSFTPGlobalTransferLimit == 3)
        #expect(SettingsKey.defaultSFTPPerHostTransferLimit == 2)
        #expect(SettingsKey.sftpTransferLimitRange == 1...8)

        let defaults = MobileSFTPTransferLimits(global: 3, perHost: 2)
        #expect(defaults.global == 3)
        #expect(defaults.perHost == 2)
        let belowRange = MobileSFTPTransferLimits(global: 0, perHost: 0)
        #expect(belowRange.global == 1)
        #expect(belowRange.perHost == 1)
        let aboveRange = MobileSFTPTransferLimits(global: 20, perHost: 20)
        #expect(aboveRange.global == 8)
        #expect(aboveRange.perHost == 8)
        let aboveGlobal = MobileSFTPTransferLimits(global: 3, perHost: 7)
        #expect(aboveGlobal.global == 3)
        #expect(aboveGlobal.perHost == 3)
    }

    @Test func sftpCoordinatorAppliesNormalizedSettingsImmediately() {
        let coordinator = SFTPTransferCoordinator(
            store: HostLibraryModel(), clientFactory: { SFTPClient() }, globalLimit: 3, perHostLimit: 2)
        let clampedAtInitialization = SFTPTransferCoordinator(
            store: HostLibraryModel(), clientFactory: { SFTPClient() }, globalLimit: 1, perHostLimit: 7)

        #expect(coordinator.globalLimit == 3)
        #expect(coordinator.perHostLimit == 2)
        #expect(clampedAtInitialization.globalLimit == 1)
        #expect(clampedAtInitialization.perHostLimit == 1)
        coordinator.updateLimits(global: 0, perHost: 7)

        #expect(coordinator.globalLimit == 1)
        #expect(coordinator.perHostLimit == 1)
    }

    @Test func testsNeverStartCloudEngines() throws {
        let app = try MobileAppModel(inMemory: true)
        app.sceneChanged(UUID(), phase: .active)
        #expect(app.vaultSync == nil)
        #expect(app.settingsSync == nil)
    }

    @Test func providerCanBeSavedWithoutModelsAndDoesNotChangeSelection() throws {
        let ai = AIConfigurationModel()
        let chosen = AIModelRef(modelProviderID: UUID(), modelID: "chosen")
        ai.select(chosen)
        let editor = MobileProviderEditorModel(ai: ai, provider: ModelProvider(name: "Gateway"))
        editor.endpoint.url = "https://example.invalid/v1"
        editor.endpoint.apiType = .responses
        editor.secret = "test-key"
        try editor.save()
        let saved = try #require(ai.modelProvider(editor.original.id))
        #expect(saved.models.isEmpty)
        #expect(saved.inferenceURL == "https://example.invalid/v1/responses")
        #expect(!saved.credentialRef.isEmpty)
        #expect(ai.lastSelectedModel == chosen)
    }

    @Test func secretFailureKeepsDraftAndDoesNotPersistProvider() throws {
        let secrets = EditorSecrets()
        secrets.failWrites = true
        let ai = AIConfigurationModel(aiSecrets: secrets)
        let editor = MobileProviderEditorModel(ai: ai, provider: ModelProvider(name: "Gateway"))
        editor.endpoint.url = "https://example.invalid/v1"
        editor.keyAction = .replace
        editor.secret = "test-key"
        #expect(throws: (any Error).self) { try editor.save() }
        #expect(ai.modelProviders.isEmpty)
        #expect(editor.secret == "test-key")
        #expect(ai.secretStorageError != nil)
    }

    @Test func metadataFailureRestoresPreviousSecret() throws {
        let provider = ModelProvider(
            name: "Before", inferenceURL: "https://example.invalid/v1/responses", credentialRef: "ref")
        let persistence = EditorPersistence(provider: provider)
        let secrets = EditorSecrets()
        secrets.values["ref"] = "before"
        let ai = AIConfigurationModel(persistence: persistence, aiSecrets: secrets)
        let editor = MobileProviderEditorModel(ai: ai, provider: provider)
        editor.draft.name = "After"
        editor.keyAction = .replace
        editor.secret = "after"
        persistence.failWrites = true
        #expect(throws: (any Error).self) { try editor.save() }
        #expect(ai.modelProvider(provider.id)?.name == "Before")
        #expect(secrets.values["ref"] == "before")
        #expect(editor.isDirty)
    }

    @Test func editingPreservesRefreshedModelsAndCanClearAKey() throws {
        let provider = ModelProvider(
            name: "Gateway", inferenceURL: "https://example.invalid/v1/responses", credentialRef: "ref")
        let secrets = EditorSecrets()
        secrets.values["ref"] = "before"
        let ai = AIConfigurationModel(modelProviders: [provider], aiSecrets: secrets)
        let editor = MobileProviderEditorModel(ai: ai, provider: provider)
        ai.addModel(AIModel(id: "new-model"), to: provider.id)
        editor.keyAction = .clear
        try editor.save()
        #expect(ai.modelProvider(provider.id)?.models.map(\.id) == ["new-model"])
        #expect(ai.modelProvider(provider.id)?.credentialRef == "")
        #expect(secrets.values["ref"] == nil)
    }

    @Test func remoteDeletionDoesNotResurrectAnOpenDraft() throws {
        let provider = ModelProvider(name: "Gateway", inferenceURL: "https://example.invalid/v1/responses")
        let ai = AIConfigurationModel(modelProviders: [provider])
        let editor = MobileProviderEditorModel(ai: ai, provider: provider)
        ai.delete(modelProviderID: provider.id)
        #expect(throws: (any Error).self) { try editor.save() }
        #expect(ai.modelProviders.isEmpty)
    }

    @Test func cancelledDiscoveryIgnoresAnUncooperativeResponse() async {
        let latch = DiscoveryLatch()
        let provider = ModelProvider(name: "Gateway")
        let ai = AIConfigurationModel(modelProviders: [provider])
        let discovery = MobileModelDiscovery(fetch: { _, _ in await latch.wait() })
        discovery.start(ai: ai, provider: provider)
        await latch.awaitStarted()
        discovery.cancel()
        await latch.finish()
        for _ in 0..<10 { await Task.yield() }
        #expect(discovery.candidates.isEmpty)
        #expect(!discovery.running)
        #expect(ai.modelProvider(provider.id)?.models.isEmpty == true)
    }

    @Test func deletedProviderIgnoresDiscoveryResponse() async {
        let latch = DiscoveryLatch()
        let provider = ModelProvider(name: "Gateway")
        let ai = AIConfigurationModel(modelProviders: [provider])
        let discovery = MobileModelDiscovery(fetch: { _, _ in await latch.wait() })
        discovery.start(ai: ai, provider: provider)
        await latch.awaitStarted()
        ai.delete(modelProviderID: provider.id)
        await latch.finish()
        for _ in 0..<10 { await Task.yield() }
        #expect(discovery.candidates.isEmpty)
    }

    @Test func terminalHistoryRequiresIntegrationAndPairsCompletionOnlyOnce() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        let workspace = MobileWorkspace(
            descriptor: .init(hostID: host.id, title: host.name, kind: .ssh),
            hosts: app.library, terminalSettings: app.terminalSettings, commandHistory: app.commandHistory)
        workspace.receiveShellEvent(.commandStarted("not-authenticated"))
        #expect(app.commandHistory.entries(for: host.id).isEmpty)
        workspace.receiveShellEvent(.available(shell: "bash", systemInfo: nil, homeDirectory: nil))
        workspace.receiveShellEvent(.commandStarted("echo hello"))
        workspace.receiveShellEvent(.commandFinished(0, duration: 1.25))
        workspace.receiveShellEvent(.commandFinished(1, duration: 9))
        let entry = try #require(app.commandHistory.entries(for: host.id).first)
        #expect(entry.command == "echo hello")
        #expect(entry.exitStatus == 0)
        #expect(entry.duration == 1.25)
        workspace.receiveShellEvent(.commandStarted("interrupted"))
        workspace.disconnect()
        workspace.receiveShellEvent(.commandFinished(0, duration: 1))
        #expect(app.commandHistory.entries(for: host.id).first?.exitStatus == nil)
    }

    @Test func findQuerySurvivesDismissalAndNavigationReopensSearch() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        let workspace = MobileWorkspace(
            descriptor: .init(hostID: host.id, title: host.name, kind: .ssh), hosts: app.library)
        workspace.presentFind()
        workspace.updateFindQuery("retained")
        workspace.dismissFind()
        workspace.presentFind()
        #expect(workspace.findQuery == "retained")
        #expect(workspace.isFindPresented)

        workspace.dismissFind()
        workspace.navigateFind(.next)
        #expect(workspace.findQuery == "retained")
        #expect(workspace.isFindPresented)
    }

    @Test func remoteHostDeletionClearsCommandHistory() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        app.commandHistory.record("test", for: host.id)
        app.applyRemoteVault(.init(), keys: [VaultRecordKey(kind: .host, id: host.id)])
        #expect(app.library.host(host.id) == nil)
        #expect(app.commandHistory.entries(for: host.id).isEmpty)
    }
}

@MainActor private final class EditorSecrets: AISecretStoring {
    var values: [String: String] = [:]
    var failWrites = false
    func string(for reference: String) throws -> String? { values[reference] }
    func setString(_ value: String?, for reference: String) throws {
        if failWrites { throw CocoaError(.fileWriteNoPermission) }
        values[reference] = value
    }
}

@MainActor private final class EditorPersistence: AIConfigurationPersisting {
    var value: AIConfigurationSnapshot
    var failWrites = false
    init(provider: ModelProvider) { value = .init(providers: [provider], roles: [:]) }
    func load() throws -> AIConfigurationSnapshot { value }
    func save(_ snapshot: AIConfigurationSnapshot) throws {
        if failWrites { throw CocoaError(.fileWriteNoPermission) }
        value = snapshot
    }
}

private actor DiscoveryLatch {
    private var continuation: CheckedContinuation<[AIModel], Never>?
    func wait() async -> [AIModel] { await withCheckedContinuation { continuation = $0 } }
    func awaitStarted() async { while continuation == nil { await Task.yield() } }
    func finish() {
        continuation?.resume(returning: [AIModel(id: "late")])
        continuation = nil
    }
}
