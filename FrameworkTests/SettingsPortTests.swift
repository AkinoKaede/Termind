import AgentKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import Testing

@Suite @MainActor
struct SettingsPortTests {
    @Test func permissionResolutionUsesTheLatestDefaultUntilAConversationChooses() {
        let ai = AIConfigurationModel(lastSelectedPermissionMode: .approveForMe)
        let conversation = ConversationModel()
        #expect(ai.resolve(conversation: conversation.permissionMode) == .approveForMe)

        conversation.permissionMode = .askForApproval
        ai.select(.fullAccess)
        #expect(ai.resolve(conversation: conversation.permissionMode) == .askForApproval)
    }

    @Test func permissionDefaultPersistsAcrossConfigurationInstances() throws {
        let domain = "SettingsPortPermission.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let first = AIConfigurationModel(permissionDefaults: defaults)
        first.select(.approveForMe)
        #expect(AIConfigurationModel(permissionDefaults: defaults).lastSelectedPermissionMode == .approveForMe)

        first.select(.fullAccess)
        #expect(AIConfigurationModel(permissionDefaults: defaults).lastSelectedPermissionMode == .fullAccess)
    }

    @Test func missingAndInvalidPermissionDefaultsRequireApproval() throws {
        let domain = "SettingsPortPermissionFallback.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        #expect(AIConfigurationModel(permissionDefaults: defaults).lastSelectedPermissionMode == .askForApproval)
        defaults.set("unknown-mode", forKey: "assistant.permissionMode")
        #expect(AIConfigurationModel(permissionDefaults: defaults).lastSelectedPermissionMode == .askForApproval)
    }

    @Test func failedTerminalSaveKeepsTheAppliedPreferences() {
        let persistence = FailingTerminalPreferences()
        let model = TerminalSettingsModel(persistence: persistence)
        #expect(!model.set("GitHub Light", for: \.lightTheme))
        #expect(model.preferences.lightTheme == "Termind Light")
        #expect(model.storageError != nil)
        model.applyRemoteSnapshot(TerminalPreferences(lightTheme: "GitHub Light"))
        #expect(model.preferences.lightTheme == "GitHub Light")
        #expect(persistence.saves == 1)
    }

    @Test func mobileSettingsEditsPreserveSkillsMCPAndUnresolvedRoles() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let domain = "SettingsPortTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try store.prepare()
        let server = MCPServer(name: "Preserved")
        let unresolved = AIModelRef(modelProviderID: UUID(), modelID: "not-arrived")
        try store.saveConfiguration(.init(providers: [], roles: [.guardian: unresolved], mcpServers: [server]))
        let skills = try store.load().skills
        let ai = AIConfigurationModel(persistence: SyncedAIConfigurationPersistence(store))
        #expect(
            ai.saveProvider(
                ModelProvider(name: "Mobile"), endpoint: ProviderEndpoint(url: "https://example.invalid/v1")))
        let saved = try store.load()
        #expect(saved.skills == skills)
        #expect(saved.configuration.mcpServers == [server])
        #expect(saved.configuration.roles[.guardian] == unresolved)
        #expect(try !store.journal.pendingEnvelopes().isEmpty)
    }

    @Test func applyingRemoteTerminalDoesNotEnterLocalWriteCallback() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let domain = "SettingsPortTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try store.prepare()
        var callbacks = 0
        store.didRecordChanges = { _ in callbacks += 1 }
        let preferences = TerminalPreferences(
            darkCustomEnabled: true, darkCustomConfiguration: "background = 123456")
        let payload = SettingsRecordPayload.terminal(preferences)
        let envelope = SettingsEnvelope(
            key: payload.key, version: .next(after: nil, writerID: UUID(), now: .now), payload: payload)
        let result = try store.applyRemote([envelope])
        #expect(result.snapshot.terminal == preferences)
        #expect(defaults.double(forKey: SettingsKey.terminalFontSize) == 12)
        #expect(callbacks == 0)
    }

    @Test func syncDefaultsPreserveIndependentSelectionsWhenPaused() {
        let domain = "SettingsPortTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        SettingsKey.migrateSyncPreferences(in: defaults)
        #expect(defaults.bool(forKey: SettingsKey.iCloudSyncEnabled))
        #expect(SettingsKey.defaultSettingsSyncEnabled)
        #expect(defaults.object(forKey: SettingsKey.settingsSyncEnabled) == nil)
        defaults.set(true, forKey: SettingsKey.settingsSyncEnabled)
        defaults.set(false, forKey: SettingsKey.iCloudSyncEnabled)
        SettingsKey.migrateSyncPreferences(in: defaults)
        #expect(!defaults.bool(forKey: SettingsKey.iCloudSyncEnabled))
        #expect(defaults.bool(forKey: SettingsKey.settingsSyncEnabled))
    }

    @Test func newVaultCredentialStorageRequiresMasterAndProRegardlessOfLegacyVaultChoice() throws {
        let domain = "VaultCredentialStorage.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        for iCloudEnabled in [false, true] {
            for vaultEnabled in [false, true] {
                for canUseVaultSync in [false, true] {
                    defaults.set(iCloudEnabled, forKey: SettingsKey.iCloudSyncEnabled)
                    defaults.set(vaultEnabled, forKey: SettingsKey.vaultSyncEnabled)
                    let expectedKey: KeyStorage =
                        iCloudEnabled && canUseVaultSync ? .iCloud : .thisDevice
                    let expectedPassword: PasswordStorage =
                        iCloudEnabled && canUseVaultSync ? .iCloud : .thisDevice

                    #expect(
                        NewVaultCredentialStorage.keyStorage(
                            defaults: defaults,
                            canUseVaultSync: canUseVaultSync) == expectedKey)
                    #expect(
                        NewVaultCredentialStorage.passwordStorage(
                            defaults: defaults,
                            canUseVaultSync: canUseVaultSync) == expectedPassword)
                }
            }
        }
    }

    @Test func newVaultCredentialStorageUsesEnabledDefaultsWhenPreferencesAreMissing() throws {
        let domain = "VaultCredentialStorageDefaults.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        #expect(NewVaultCredentialStorage.keyStorage(defaults: defaults, canUseVaultSync: true) == .iCloud)
        #expect(NewVaultCredentialStorage.passwordStorage(defaults: defaults, canUseVaultSync: true) == .iCloud)
    }

    @Test func rolesTakePrecedenceOverLastSelectedModelAndDeletedModelsFallBack() {
        let provider = ModelProvider(name: "Test", models: [AIModel(id: "role"), AIModel(id: "last")])
        let role = AIModelRef(modelProviderID: provider.id, modelID: "role")
        let last = AIModelRef(modelProviderID: provider.id, modelID: "last")
        let ai = AIConfigurationModel(modelProviders: [provider], roles: [.chat: role], lastSelectedModel: last)
        #expect(ai.resolve(conversation: nil as AIModelRef?)?.model.id == "role")
        ai.removeModels(["role"], from: provider.id)
        #expect(ai.resolve(.chat)?.model.id == "last")
    }

    @Test func historyRetainsTheNewestSharedLimitAndUnknownCompletion() {
        let model = CommandHistoryModel()
        #expect(model.record(" \n\t ") == nil)
        for index in 0...CommandHistoryModel.perSessionLimit {
            model.record("command \(index)")
        }
        let values = model.entries()
        #expect(values.count == CommandHistoryModel.perSessionLimit)
        #expect(values.first?.command == "command \(HistoryLimits.retainedEntries)")
        #expect(values.last?.command == "command 1")
        #expect(values.allSatisfy { $0.exitStatus == nil && $0.duration == nil })
    }

}

@MainActor private final class FailingTerminalPreferences: TerminalPreferencesPersisting {
    var saves = 0
    func loadTerminal() throws -> TerminalPreferences { .init() }
    func saveTerminal(_ value: TerminalPreferences) throws {
        saves += 1
        throw CocoaError(.fileWriteNoPermission)
    }
}
