import AgentKit
import CloudKit
import CoreData
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite
@MainActor
struct SettingsSyncTests {
    private func fixture() throws -> (ModelContainer, SettingsSyncPersistence, UserDefaults) {
        let container = try ModelContainer(
            for: HostPersistence.schema,
            configurations: localModelConfiguration(isStoredInMemoryOnly: true))
        let defaults = UserDefaults(suiteName: "SettingsSyncTests.\(UUID())")!
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try store.prepare()
        return (container, store, defaults)
    }

    private func provider(_ name: String = "Private endpoint") -> ModelProvider {
        var model = AIModel(id: "private-chat")
        model.contextLength = 123_456
        model.isShownInAssistant = false
        model.reasoningProfile = ReasoningProfile(levels: [
            .high: ReasoningLevelMapping(isSupported: true, wireValue: "deep")
        ])
        return ModelProvider(
            name: name, inferenceURL: "https://example.invalid/v1/responses",
            credentialRef: "termind.ai.key.\(UUID())", models: [model])
    }

    private func envelope(_ payload: SettingsRecordPayload, time: TimeInterval = 1) -> SettingsEnvelope {
        SettingsEnvelope(
            key: payload.key,
            version: .next(after: nil, writerID: UUID(), now: Date(timeIntervalSince1970: time)),
            payload: payload)
    }

    @Test
    func schemaV13RetainsItsInstalledEntityHashes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("V13Hashes-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Store.sqlite")
        let schema = Schema(versionedSchema: TermindSchemaV13.self)
        let container = try ModelContainer(
            for: schema,
            configurations: localModelConfiguration("V13", schema: schema, url: url))
        defer { withExtendedLifetime(container) {} }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
        let hashes = try #require(metadata[NSStoreModelVersionHashesKey] as? [String: Data])
        let expected = [
            "PersistentAIConfigurationSyncEntry": "005de4241162667db1f82f46fabcabc1401dc22a3a4e9586d798787dc5e26281",
            "PersistentAIConfigurationSyncState": "72ccff1781b06084d643d3ea43ad62ac85ac9840835db04aaae34b4776d74998",
            "PersistentAIConfigurationSyncQuarantine":
                "1ad4dabecf147f68f4419de6a0818b554932822dfb8e83a8e02560ad48b2b452",
            "PersistentAIWebSearchPreferences": "01922c7bda7dd72129b8e0e8079eb39ac44718aa5421160038defcda4c6ddb37",
            "PersistentAISecretLocation": "3a0b34347788b6e9da55f343572be6dc942d0b576c72039f520a21724d26bf87",
        ]
        for (name, expectedHash) in expected {
            #expect(hashes[name]?.map { String(format: "%02x", $0) }.joined() == expectedHash)
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: settingsMigrationFixtureURL.path)))
    func providedDatabaseCopyMigratesWithoutReset() throws {
        let container = try ModelContainer(
            for: HostPersistence.schema, migrationPlan: TermindMigrationPlan.self,
            configurations: localModelConfiguration(
                "Termind", schema: HostPersistence.schema, url: settingsMigrationFixtureURL))
        let defaults = UserDefaults(suiteName: "SettingsMigrationFixture.\(UUID())")!
        defaults.set(AgentSkillLibrary.currentGeneration, forKey: SettingsKey.seededSkillGeneration)
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try store.prepare()
        _ = try store.load()
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: settingsMigrationFixtureURL)
        #expect(metadata[NSStoreModelVersionIdentifiersKey] as? [String] == ["15.0.0"])
    }

    @Test
    func schemaV12MigratesProvidersSkillsAndPreferencesWithoutMaterializingSyncSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AISyncMigration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Store.sqlite")
        let oldSchema = Schema(versionedSchema: TermindSchemaV12.self)
        let provider = provider()
        let endpoint = ProviderEndpoint(apiType: .responses, url: "https://example.invalid/v1")
        let skill = AgentSkill(name: "custom", title: "Custom", summary: "Mine", body: "Do this")
        var legacy: ModelContainer? = try ModelContainer(
            for: oldSchema,
            configurations: localModelConfiguration("Migration", schema: oldSchema, url: url))
        try AIPersistence(context: legacy!.mainContext).save(
            AIConfigurationSnapshot(
                providers: [provider], endpoints: [provider.id: endpoint], roles: [:]))
        try SkillPersistence(context: legacy!.mainContext).save([skill])
        legacy = nil
        let migrated = try ModelContainer(
            for: HostPersistence.schema, migrationPlan: TermindMigrationPlan.self,
            configurations: localModelConfiguration("Migration", schema: HostPersistence.schema, url: url))
        let defaults = UserDefaults(suiteName: "AISyncMigration.\(UUID())")!
        defaults.set(false, forKey: SettingsKey.webSearchEnabled)
        defaults.set(17.0, forKey: SettingsKey.terminalFontSize)
        defaults.set("font-family = Menlo", forKey: SettingsKey.terminalCustomConfigurationDark)
        defaults.set(1, forKey: SettingsKey.seededSkillGeneration)
        let store = SettingsSyncPersistence(context: migrated.mainContext, defaults: defaults)
        try store.prepare()
        let snapshot = try store.load()
        #expect(snapshot.configuration.providers.first?.id == provider.id)
        #expect(snapshot.configuration.endpoints[provider.id] == endpoint)
        #expect(snapshot.configuration.providers.first?.models == provider.models)
        #expect(snapshot.skills == [skill])
        #expect(!snapshot.webSearch.isEnabled)
        #expect(snapshot.terminal.fontSize == 17)
        #expect(snapshot.terminal.darkCustomConfiguration == "font-family = Menlo")
        #expect(defaults.object(forKey: SettingsKey.settingsSyncEnabled) == nil)
    }

    @Test
    func completedV13BootstrapAddsTerminalWithoutRewritingExistingRecords() throws {
        let (container, store, defaults) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let previous = try store.journal.pendingEnvelopes().filter { $0.key.kind != .terminal }
        try container.mainContext.delete(
            model: PersistentAIConfigurationSyncEntry.self,
            where: #Predicate { $0.kind == "terminal" })
        try container.mainContext.delete(model: PersistentTerminalPreferences.self)
        try container.mainContext.save()
        defaults.set(17.0, forKey: SettingsKey.terminalFontSize)
        try store.prepare()
        let terminal = try #require(try store.journal.pendingEnvelopes().first { $0.key.kind == .terminal })
        #expect(terminal.version.modifiedAt == VaultVersion.baselineDate)
        #expect(try store.loadTerminal().fontSize == 17)
        for old in previous { #expect(try store.journal.envelope(for: old.key) == old) }
    }

    @Test
    func terminalPreferencesSyncWithCustomTextAndMirrorExistingRuntimeKeys() throws {
        let (sourceContainer, source, sourceDefaults) = try fixture()
        let (destinationContainer, destination, defaults) = try fixture()
        defer { withExtendedLifetime((sourceContainer, destinationContainer)) {} }
        var preferences = TerminalPreferences()
        preferences.fontSize = 18
        preferences.fontFollowTheme = false
        preferences.darkTheme = "Catppuccin Mocha"
        preferences.lightTheme = "GitHub Light"
        preferences.darkCustomEnabled = true
        preferences.lightCustomEnabled = true
        preferences.darkCustomConfiguration = "background = #112233\nfont-family = Menlo"
        preferences.lightCustomConfiguration = "background = #ffffff"
        preferences.shellIntegration = false
        preferences.remoteWindowTitleInMenuBar = false
        try source.saveTerminal(preferences)
        #expect(sourceDefaults.double(forKey: SettingsKey.terminalFontSize) == 18)
        let records = try source.journal.pendingEnvelopes().filter { $0.key.kind == .terminal }
        let result = try destination.applyRemote(records)
        #expect(result.snapshot.terminal == preferences)
        #expect(
            defaults.string(forKey: SettingsKey.terminalCustomConfigurationDark) == preferences.darkCustomConfiguration)
        #expect(!defaults.bool(forKey: SettingsKey.shellIntegration))
        #expect(try !destination.journal.pendingEnvelopes().contains { $0.key.kind == .terminal })
        let model = TerminalSettingsModel(persistence: destination)
        var changes: [Bool] = []
        model.didChangeShellIntegration = { changes.append($0) }
        #expect(model.set(true, for: \.shellIntegration))
        #expect(changes == [true])
        #expect(try destination.loadTerminal().shellIntegration)
        model.applyRemoteSnapshot(preferences)
        #expect(changes == [true, false])
    }

    @Test
    func everyRecordRoundTripsWithoutSecretsOrLocalExecutionSettings() throws {
        let (container, store, _) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let provider = provider()
        var snapshot = try store.load()
        snapshot.configuration.providers = [provider]
        snapshot.configuration.endpoints[provider.id] = ProviderEndpoint(
            apiType: .responses, url: "https://example.invalid/v1")
        let ref = AIModelRef(modelProviderID: provider.id, modelID: provider.models[0].id)
        snapshot.configuration.roles[.chat] = ref
        snapshot.configuration.lastSelectedModel = ref
        snapshot.configuration.mcpServers = [
            MCPServer(
                name: "Remote", credentialRef: "termind.ai.mcp.ref",
                headers: [MCPHeader(name: "X-Tenant", value: "tenant")], tools: [MCPTool(id: "read")])
        ]
        for payload in snapshot.recordPayloads.values {
            let value = envelope(payload)
            let data = try SettingsSyncCodec.encode(value)
            #expect(try SettingsSyncCodec.decode(data) == value)
            #expect(SettingsRecordKey(recordName: value.key.recordName) == value.key)
            let json = String(decoding: data, as: UTF8.self)
            #expect(!json.contains("permissionMode"))
            #expect(!json.contains("lastConnectedAt"))
            #expect(!json.contains(MCPServerTokenStore.reference))
            let record = try SettingsSyncCoordinator.makeRecord(
                SettingsOutgoingEntry(envelope: value),
                recordID: CKRecord.ID(
                    recordName: value.key.recordName,
                    zoneID: CKRecordZone.ID(zoneName: SettingsSyncCoordinator.zoneName)))
            #expect(try SettingsSyncCoordinator.envelope(from: record) == value)
        }
        let wire = SyncedModelProvider(provider, endpoint: snapshot.configuration.endpoints[provider.id]!, sortIndex: 0)
        #expect(wire.value.models == provider.models)
    }

    @Test
    func localEditsAreJournaledWhileDisabledAndNoOpsDoNotAdvanceVersions() throws {
        let (container, store, defaults) = try fixture()
        defer { withExtendedLifetime(container) {} }
        defaults.set(false, forKey: SettingsKey.settingsSyncEnabled)
        #expect(!defaults.bool(forKey: SettingsKey.settingsSyncEnabled))
        var snapshot = try store.load().configuration
        let provider = provider()
        snapshot.providers.append(provider)
        try store.saveConfiguration(snapshot)
        let key = SettingsRecordKey(kind: .provider, id: provider.id.uuidString.lowercased())
        let original = try #require(try store.journal.envelope(for: key))
        try store.saveConfiguration(snapshot)
        #expect(try store.journal.envelope(for: key) == original)
        snapshot.providers.removeAll()
        try store.saveConfiguration(snapshot)
        #expect(try store.journal.envelope(for: key)?.isDeleted == true)
        let merged = try store.applyRemote([original])
        #expect(merged.snapshot.configuration.providers.isEmpty)
        #expect(merged.needsUpload.contains(key))
    }

    @Test
    func newDeviceDefaultsDoNotReplaceCloudPreferencesAndBuiltInDeletion() throws {
        let (sourceContainer, source, _) = try fixture()
        defer { withExtendedLifetime(sourceContainer) {} }
        let (destinationContainer, destination, _) = try fixture()
        defer { withExtendedLifetime(destinationContainer) {} }
        try source.saveWebSearch(AIWebSearchPreferences(isEnabled: false, prefersBuiltIn: false))
        try source.saveSkills([])
        let result = try destination.applyRemote(source.journal.pendingEnvelopes())
        #expect(result.snapshot.skills.isEmpty)
        #expect(!result.snapshot.webSearch.isEnabled)
        try destination.prepare()
        #expect(try destination.load().skills.isEmpty)
    }

    @Test
    func roleArrivingBeforeProviderSurvivesRelaunchAndUnrelatedEdit() throws {
        let (container, store, defaults) = try fixture()
        let provider = provider()
        let ref = AIModelRef(modelProviderID: provider.id, modelID: provider.models[0].id)
        let role = envelope(.role(.chat, ref))
        _ = try store.applyRemote([role])
        let reopened = SettingsSyncPersistence(context: ModelContext(container), defaults: defaults)
        var config = try reopened.load().configuration
        #expect(config.roles[.chat] == ref)
        config.mcpServers = [MCPServer(name: "Unrelated")]
        try reopened.saveConfiguration(config)
        let value = SyncedModelProvider(provider, endpoint: ProviderEndpoint(url: provider.inferenceURL), sortIndex: 0)
        let result = try reopened.applyRemote([envelope(.provider(value), time: 2)])
        #expect(result.snapshot.configuration.roles[.chat] == ref)
        let deletion = SettingsEnvelope(
            key: valueKey(provider),
            version: .next(after: nil, writerID: UUID(), now: Date(timeIntervalSince1970: 3)), isDeleted: true)
        let deleted = try reopened.applyRemote([deletion])
        #expect(deleted.snapshot.configuration.roles[.chat] == nil)
    }

    private func valueKey(_ provider: ModelProvider) -> SettingsRecordKey {
        SettingsRecordKey(kind: .provider, id: provider.id.uuidString.lowercased())
    }

    @Test
    func differentProvidersMergeAndLatestVersionWinsRegardlessOfBatchOrder() throws {
        let (container, store, _) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let first = provider("First")
        let second = provider("Second")
        let endpoint = ProviderEndpoint(url: first.inferenceURL)
        let old = envelope(.provider(SyncedModelProvider(first, endpoint: endpoint, sortIndex: 0)), time: 1)
        var changed = first
        changed.name = "Updated"
        let newer = envelope(.provider(SyncedModelProvider(changed, endpoint: endpoint, sortIndex: 0)), time: 5)
        let other = envelope(.provider(SyncedModelProvider(second, endpoint: endpoint, sortIndex: 1)), time: 2)
        let result = try store.applyRemote([newer, other, old])
        #expect(result.snapshot.configuration.providers.count == 2)
        #expect(result.snapshot.configuration.providers.first?.name == "Updated")
    }

    @Test
    func invalidBatchRollsBackConfigurationAndJournal() throws {
        let (container, store, _) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let before = try store.load().webSearch
        let valid = envelope(.webSearch(.init(isEnabled: false, prefersBuiltIn: false)))
        var invalid = envelope(.terminal(TerminalPreferences()))
        invalid.formatVersion = 99
        #expect(throws: (any Error).self) { try store.applyRemote([valid, invalid]) }
        #expect(try store.load().webSearch == before)
        #expect(try store.journal.envelope(for: valid.key)?.version.modifiedAt == VaultVersion.baselineDate)
    }

    @Test
    func environmentResetRetainsDeletesButAccountMergeDoesNotUploadOldAccountDeletes() throws {
        let (container, store, _) = try fixture()
        defer { withExtendedLifetime(container) {} }
        try store.saveSkills([])
        try store.journal.markAllEntriesNeedsUploadAfterEnvironmentChange()
        #expect(try store.journal.pendingEnvelopes().contains(where: \.isDeleted))
        try store.journal.markAllLiveRecordsNeedsUploadForNewAccount()
        #expect(try !store.journal.pendingEnvelopes().contains(where: \.isDeleted))
    }

    @Test
    func legacyBuiltInsGetStableIDsWithoutDiscardingCustomizations() {
        let shipped = AgentSkillLibrary.builtIns(after: 0)
        var unchanged = shipped[0]
        unchanged.id = UUID()
        var edited = shipped[1]
        edited.id = UUID()
        edited.body += "\nMy edits"
        let result = SettingsSyncPersistence.normalizeBuiltIns([unchanged, edited], seededGeneration: 1)
        #expect(result.skills.first?.id == shipped[0].id)
        #expect(result.skills.contains { $0 == edited })
        #expect(result.deleted == [shipped[1].id, shipped[2].id])
        #expect(Set(shipped.map(\.id)) == Set(AgentSkillLibrary.builtIns(after: 0).map(\.id)))
    }

    @Test
    func collisionsAreDeterministicallyExcludedWithoutRewritingUserRecords() {
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = MCPServer(id: low, name: "Shared")
        let second = MCPServer(id: high, name: "Shared")
        let ai = AIConfigurationModel(mcpServers: [second, first], persistsSecrets: false)
        #expect(ai.usableMCPServers.map(\.id) == [low])
        #expect(ai.mcpServers.allSatisfy { $0.isEnabled })
        let library = SkillLibraryModel(skills: [
            AgentSkill(id: high, name: "shared", title: "Second", summary: "Procedure", body: "Second"),
            AgentSkill(id: low, name: "shared", title: "First", summary: "Procedure", body: "First"),
        ])
        #expect(library.enabledSkills.map(\.id) == [low])
    }

    @Test
    func mainSwitchPausesBothCategoriesWithoutClearingSelections() throws {
        let (container, store, defaults) = try fixture()
        SettingsKey.migrateSyncPreferences(in: defaults)
        #expect(defaults.bool(forKey: SettingsKey.iCloudSyncEnabled))
        #expect(defaults.object(forKey: SettingsKey.vaultSyncEnabled) as? Bool ?? SettingsKey.defaultVaultSyncEnabled)
        #expect(defaults.object(forKey: SettingsKey.settingsSyncEnabled) == nil)
        let vault = VaultSyncCoordinator(context: container.mainContext, defaults: defaults)
        let ai = SettingsSyncCoordinator(
            persistence: store,
            secrets: AISecretStore(context: container.mainContext, keychain: SyncTestSecrets()), defaults: defaults)
        #expect(vault.isEnabled && ai.isEnabled)
        defaults.set(false, forKey: SettingsKey.iCloudSyncEnabled)
        #expect(!vault.isEnabled && !ai.isEnabled)
        #expect(defaults.object(forKey: SettingsKey.settingsSyncEnabled) == nil)
        defaults.set(true, forKey: SettingsKey.iCloudSyncEnabled)
        #expect(vault.isEnabled && ai.isEnabled)
        defaults.set(false, forKey: SettingsKey.vaultSyncEnabled)
        #expect(!vault.isEnabled && ai.isEnabled)
    }

    @Test
    func newSettingsDefaultKeepsMainSyncOnWhenVaultWasDisabled() {
        let defaults = UserDefaults(suiteName: "AISyncPreferenceMigration.\(UUID())")!
        defaults.set(false, forKey: SettingsKey.vaultSyncEnabled)
        SettingsKey.migrateSyncPreferences(in: defaults)
        #expect(defaults.bool(forKey: SettingsKey.iCloudSyncEnabled))
        #expect(!defaults.bool(forKey: SettingsKey.vaultSyncEnabled))
        #expect(defaults.object(forKey: SettingsKey.settingsSyncEnabled) == nil)
        #expect(
            defaults.object(forKey: SettingsKey.settingsSyncEnabled) as? Bool
                ?? SettingsKey.defaultSettingsSyncEnabled)
    }

    @Test
    func explicitSettingsOptOutRemainsDisabledDuringPreferenceMigration() {
        let defaults = UserDefaults(suiteName: "AISyncPreferenceOptOutMigration.\(UUID())")!
        defaults.set(false, forKey: SettingsKey.vaultSyncEnabled)
        defaults.set(false, forKey: SettingsKey.settingsSyncEnabled)
        SettingsKey.migrateSyncPreferences(in: defaults)
        #expect(!defaults.bool(forKey: SettingsKey.iCloudSyncEnabled))
        #expect(defaults.bool(forKey: SettingsKey.vaultSyncEnabled))
        #expect(!defaults.bool(forKey: SettingsKey.settingsSyncEnabled))
    }

    @Test
    func independentSwitchesUseDefaultsAndHonorExplicitOptOut() throws {
        let (container, store, defaults) = try fixture()
        defaults.set(true, forKey: SettingsKey.vaultSyncEnabled)
        let vault = VaultSyncCoordinator(context: container.mainContext, defaults: defaults)
        let ai = SettingsSyncCoordinator(
            persistence: store,
            secrets: AISecretStore(context: container.mainContext, keychain: SyncTestSecrets()), defaults: defaults)
        #expect(vault.isEnabled && ai.isEnabled)
        vault.setEnabled(false)
        #expect(ai.isEnabled)
        defaults.set(false, forKey: SettingsKey.settingsSyncEnabled)
        #expect(!ai.isEnabled)
        #expect(!vault.isEnabled)
        ai.pause()
    }

    @Test
    func keysMigrateRetryAndRemainSyncedWhenConfigurationPauses() throws {
        let (container, _, _) = try fixture()
        let keychain = SyncTestSecrets()
        let secrets = AISecretStore(context: container.mainContext, keychain: keychain)
        let ref = "termind.ai.key.test"
        try secrets.setString("original", for: ref)
        #expect(try keychain.string(for: ref, storage: .iCloud) == nil)
        secrets.uploadsAuthorized = true
        keychain.failCloudWrites = true
        #expect(throws: (any Error).self) { try secrets.migrate([ref]) }
        #expect(try keychain.string(for: ref, storage: .thisDevice) == "original")
        keychain.failCloudWrites = false
        try secrets.migrate([ref])
        #expect(try keychain.string(for: ref, storage: .thisDevice) == nil)
        secrets.uploadsAuthorized = false
        try secrets.setString("new", for: ref)
        #expect(try keychain.string(for: ref, storage: .iCloud) == "new")
        try keychain.setString("other device", for: ref, storage: .iCloud)
        #expect(try secrets.string(for: ref) == "other device")
        try secrets.setString(nil, for: ref)
        try keychain.setString("delayed stale item", for: ref, storage: .iCloud)
        #expect(try secrets.string(for: ref) == nil)
    }

    @Test
    func remoteMCPTokenMigratesWithoutSelectingTheBuiltInServerToken() throws {
        let (container, _, _) = try fixture()
        let keychain = SyncTestSecrets()
        let secrets = AISecretStore(context: container.mainContext, keychain: keychain)
        let remoteReference = "termind.ai.mcp.remote"
        try secrets.setString("remote", for: remoteReference)
        try keychain.setString(
            "listener", for: MCPServerTokenStore.reference, storage: .thisDevice)

        secrets.uploadsAuthorized = true
        try secrets.migrate([remoteReference])

        #expect(try keychain.string(for: remoteReference, storage: .iCloud) == "remote")
        #expect(try keychain.string(for: MCPServerTokenStore.reference, storage: .thisDevice) == "listener")
        #expect(try keychain.string(for: MCPServerTokenStore.reference, storage: .iCloud) == nil)
    }

    @Test
    func remoteKeyCanArriveAfterConfigurationWithoutUsingStaleLocalCopy() throws {
        let (container, _, _) = try fixture()
        let keychain = SyncTestSecrets()
        let secrets = AISecretStore(context: container.mainContext, keychain: keychain)
        let ref = "termind.ai.mcp.delayed"
        try keychain.setString("stale", for: ref, storage: .thisDevice)
        try secrets.acceptRemoteReferences([ref])
        #expect(try secrets.string(for: ref) == nil)
        try keychain.setString("arrived", for: ref, storage: .iCloud)
        #expect(try secrets.string(for: ref) == "arrived")
    }
}

private nonisolated final class SyncTestSecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var failCloudWrites = false
    func string(for account: String, storage: PasswordStorage) throws -> String? {
        lock.withLock { values["\(storage):\(account)"] }
    }
    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        try lock.withLock {
            if storage == .iCloud, failCloudWrites { throw KeychainSecretError.unexpectedValue }
            values["\(storage):\(account)"] = value
        }
    }
    func keyCredential(for account: String, storage: KeyStorage) throws -> StoredSSHKeyCredential? { nil }
    func setKeyCredential(_ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage) throws {}
    func removePassword(_ account: String, storage: PasswordStorage) throws {
        try setString(nil, for: account, storage: storage)
    }
    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {}
}

private nonisolated var settingsMigrationFixtureURL: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("TermindMigrationValidation/Termind.store")
}
