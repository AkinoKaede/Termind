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
    @Test func failedTerminalSaveKeepsTheAppliedPreferences() {
        let persistence = FailingTerminalPreferences()
        let model = TerminalSettingsModel(persistence: persistence)
        #expect(!model.set(20, for: \.fontSize))
        #expect(model.preferences.fontSize == 12)
        #expect(model.storageError != nil)
        model.applyRemoteSnapshot(TerminalPreferences(fontSize: 18))
        #expect(model.preferences.fontSize == 18)
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
        try store.saveConfiguration(.init(providers: [], roles: [.securityReview: unresolved], mcpServers: [server]))
        let skills = try store.load().skills
        let ai = AIConfigurationModel(persistence: SyncedAIConfigurationPersistence(store))
        #expect(
            ai.saveProvider(
                ModelProvider(name: "Mobile"), endpoint: ProviderEndpoint(url: "https://example.invalid/v1")))
        let saved = try store.load()
        #expect(saved.skills == skills)
        #expect(saved.configuration.mcpServers == [server])
        #expect(saved.configuration.roles[.securityReview] == unresolved)
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
            fontSize: 19, darkCustomEnabled: true, darkCustomConfiguration: "background = 123456")
        let payload = SettingsRecordPayload.terminal(preferences)
        let envelope = SettingsEnvelope(
            key: payload.key, version: .next(after: nil, writerID: UUID(), now: .now), payload: payload)
        let result = try store.applyRemote([envelope])
        #expect(result.snapshot.terminal == preferences)
        #expect(defaults.double(forKey: SettingsKey.terminalFontSize) == 19)
        #expect(callbacks == 0)
    }

    @Test func syncDefaultsPreserveIndependentSelectionsWhenPaused() {
        let domain = "SettingsPortTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        SettingsKey.migrateSyncPreferences(in: defaults)
        #expect(defaults.bool(forKey: SettingsKey.iCloudSyncEnabled))
        #expect(defaults.object(forKey: SettingsKey.settingsSyncEnabled) == nil)
        defaults.set(true, forKey: SettingsKey.settingsSyncEnabled)
        defaults.set(false, forKey: SettingsKey.iCloudSyncEnabled)
        SettingsKey.migrateSyncPreferences(in: defaults)
        #expect(!defaults.bool(forKey: SettingsKey.iCloudSyncEnabled))
        #expect(defaults.bool(forKey: SettingsKey.settingsSyncEnabled))
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

    @Test func historyRetainsTheNewestThousandAndUnknownCompletion() {
        let model = CommandHistoryModel()
        let host = UUID()
        for index in 0...CommandHistoryModel.perHostLimit {
            model.record("command \(index)", for: host, at: Date(timeIntervalSince1970: Double(index)))
        }
        let values = model.entries(for: host)
        #expect(values.count == 1_000)
        #expect(values.first?.command == "command 1000")
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
