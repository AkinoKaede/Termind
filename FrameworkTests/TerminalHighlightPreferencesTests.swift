import CloudKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import Testing

@Suite @MainActor
struct TerminalHighlightPreferencesTests {
    @Test func defaultsAreStableAndUseSixExistingColors() throws {
        let value = TerminalHighlightPreferences()
        #expect(value.isEnabled && value.isValid)
        #expect(value.rules.isEmpty)
        #expect(value.effectiveRules.count == 6)
        #expect(value.effectiveRules.map(\.color) == [.red, .yellow, .green, .blue, .purple, .teal])
        #expect(value.rules == TerminalHighlightPreferences().rules)
        #expect(try JSONDecoder().decode(TerminalHighlightPreferences.self, from: JSONEncoder().encode(value)) == value)
        #expect(TerminalHighlightPreferences(rules: []).isValid)
    }

    @Test func builtInsStayOutsideEditablePreferences() {
        let model = TerminalHighlightSettingsModel()
        for rule in TerminalHighlightPreferences.builtInRules {
            var edited = rule
            edited.pattern = "changed"
            #expect(!model.upsert(edited, validate: { _ in true }))
            #expect(!model.save(.init(rules: [edited])))
        }
        #expect(model.save(.init(isEnabled: false)))
        #expect(!model.preferences.isEnabled)
        #expect(model.preferences.rules.isEmpty)
        #expect(model.preferences.effectiveRules == TerminalHighlightPreferences.builtInRules)
    }

    @Test func customRulesRemainEditableAndDeletable() {
        let model = TerminalHighlightSettingsModel()
        var rule = TerminalHighlightRule(name: "Custom", pattern: "hello", color: .none)
        #expect(!rule.isBuiltIn)
        #expect(model.upsert(rule, validate: { _ in true }))
        rule.name = "Edited"
        rule.pattern = "world"
        rule.backgroundColor = .pink
        #expect(model.upsert(rule, validate: { _ in true }))
        #expect(model.preferences.rules.last == rule)
        var changed = model.preferences
        changed.rules.removeAll { $0.id == rule.id }
        #expect(model.save(changed))
        #expect(model.preferences == TerminalHighlightPreferences())
    }

    @Test func noColorIsValidAndDuplicateIDsAndExcessiveRulesAreRejected() throws {
        var value = TerminalHighlightPreferences(rules: [.init(name: "Custom", pattern: "x", color: .none)])
        #expect(value.isValid)
        #expect(
            SettingsEnvelope(
                key: .init(kind: .terminalHighlighting, id: "default"),
                version: .baseline(writerID: UUID()), payload: .terminalHighlighting(value)
            ).isValid)
        value.rules.append(value.rules[0])
        #expect(!value.isValid)
        value.rules = (0...64).map { .init(name: "Rule \($0)", pattern: "x") }
        #expect(!value.isValid)
    }

    @Test func failedSaveAndInvalidPatternKeepLastCommittedPreferences() {
        let store = HighlightStore()
        let model = TerminalHighlightSettingsModel(persistence: store)
        store.fails = true
        #expect(!model.save(.init(isEnabled: false)))
        #expect(model.preferences == TerminalHighlightPreferences())
        #expect(model.storageError != nil)
        #expect(!model.upsert(.init(name: "Invalid", pattern: "[", mode: .regularExpression), validate: { _ in false }))
        model.applyRemoteSnapshot(.init(rules: []))
        #expect(model.preferences.rules.isEmpty)
        #expect(model.storageError == nil)
        #expect(store.value == TerminalHighlightPreferences())
    }

    @Test func independentCloudRecordRoundTripsWithoutEchoOrTerminalSettingLoss() throws {
        let domain = "TerminalHighlightSync.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let sourceContainer = try TermindPersistence.makeContainer(inMemory: true)
        let destinationContainer = try TermindPersistence.makeContainer(inMemory: true)
        let source = SettingsSyncPersistence(context: sourceContainer.mainContext, defaults: defaults)
        let destination = SettingsSyncPersistence(context: destinationContainer.mainContext, defaults: defaults)
        try source.prepare()
        try destination.prepare()
        let value = TerminalHighlightPreferences(
            isEnabled: false, rules: [.init(name: "Custom", pattern: "Warn", color: .none, backgroundColor: .blue)])
        try source.saveTerminalHighlightPreferences(value)
        let key = SettingsRecordKey(kind: .terminalHighlighting, id: "default")
        let envelope = try #require(try source.journal.envelope(for: key))
        let record = try SettingsSyncCoordinator.makeRecord(
            .init(envelope: envelope), recordID: .init(recordName: key.recordName))
        #expect(record.recordType == "TerminalHighlightPreferencesItem")
        #expect(record["payload"] == nil && record["payloadAsset"] == nil && record["payloadHash"] == nil)
        #expect(record["rulePatterns"] as? [String] == ["Warn"])
        #expect(record["ruleForegroundColors"] as? [String] == ["none"])
        #expect(record["ruleBackgroundColors"] as? [String] == ["blue"])
        var callbacks = 0
        destination.didRecordChanges = { _ in callbacks += 1 }
        let result = try destination.applyRemote([SettingsSyncCoordinator.envelope(from: record)])
        #expect(
            result.snapshot.terminalHighlighting == value
        )
        #expect(callbacks == 0)
        #expect(!result.needsUpload.contains(key))
        // An older app's terminal-theme record cannot drop the independent highlight record.
        let legacy = SettingsRecordPayload.terminal(.init(darkTheme: "Dracula"))
        _ = try destination.applyRemote([
            .init(key: legacy.key, version: .next(after: nil, writerID: UUID()), payload: legacy)
        ])
        #expect(
            try destination.loadTerminalHighlightPreferences()
                == value)
        try destination.saveTerminalHighlightPreferences(.init(rules: []))
        try destination.prepare()
        #expect(try destination.loadTerminalHighlightPreferences().rules.isEmpty)
        #expect(try destination.loadTerminal().darkTheme == "Dracula")
    }

    @Test func version46StoresEmptyRulesAndBackgroundColorsAfterReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for value in [
            TerminalHighlightPreferences(rules: []),
            .init(rules: [.init(name: "Background", pattern: "Warn", color: .none, backgroundColor: .yellow)]),
        ] {
            let url = directory.appendingPathComponent(UUID().uuidString + ".store")
            try writeVersion45Store(url)
            try saveUpgradedStore(url, value: value)
            let reopened = try TermindPersistence.makeContainer(url: url)
            let rows = try reopened.mainContext.fetch(FetchDescriptor<PersistentTerminalHighlightPreferences>())
            #expect(try rows.first?.load() == value)
            let terminal = try reopened.mainContext.fetch(FetchDescriptor<PersistentTerminalPreferences>())
            #expect(try terminal.first?.load().copyOnSelect == true)
        }
        #expect(TermindSchemaV46.models.contains { $0 == PersistentTerminalHighlightPreferences.self })
        #expect(!TermindSchemaV45.models.contains { $0 == PersistentTerminalHighlightPreferences.self })
        #expect(TermindMigrationPlan.schemas.last?.versionIdentifier == Schema.Version(46, 0, 0))
    }

    @Test func nativeCloudFieldsRejectMalformedRulesAndPreserveEmptyAndDeletedStates() throws {
        let key = SettingsRecordKey(kind: .terminalHighlighting, id: "default")
        for value in [TerminalHighlightPreferences(), .init(isEnabled: false, rules: [])] {
            let envelope = SettingsEnvelope(
                key: key, version: .baseline(writerID: UUID()), payload: .terminalHighlighting(value))
            let record = try SettingsSyncCoordinator.makeRecord(
                .init(envelope: envelope), recordID: .init(recordName: key.recordName))
            #expect(try SettingsSyncCoordinator.envelope(from: record) == envelope)
            record["ruleCount"] = NSNumber(value: 65)
            #expect(throws: (any Error).self) { try SettingsSyncCoordinator.envelope(from: record) }
        }
        let deleted = SettingsEnvelope(key: key, version: .baseline(writerID: UUID()), isDeleted: true)
        let record = try SettingsSyncCoordinator.makeRecord(
            .init(envelope: deleted), recordID: .init(recordName: key.recordName))
        #expect(try SettingsSyncCoordinator.envelope(from: record) == deleted)
        #expect(record["payload"] == nil)
    }

    @Test func malformedNativeArraysAreRejectedAndOrderIsPreserved() throws {
        let value = TerminalHighlightPreferences(
            rules: (0..<6).map { .init(name: "Custom \($0)", pattern: "pattern\($0)") })
        let payload = SettingsRecordPayload.terminalHighlighting(value)
        let envelope = SettingsEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        let mutations: [(String, any CKRecordValueProtocol)] = [
            ("ruleIDs", Array(repeating: UUID().uuidString, count: 6) as NSArray),
            ("rulePatterns", ["only one"] as NSArray),
            ("ruleBackgroundColors", Array(repeating: "invalid", count: 6) as NSArray),
            ("ruleCaseSensitive", Array(repeating: NSNumber(value: 2), count: 6) as NSArray),
            ("formatVersion", NSNumber(value: 999)),
        ]
        for (field, badValue) in mutations {
            let record = try SettingsSyncCoordinator.makeRecord(
                .init(envelope: envelope), recordID: .init(recordName: payload.key.recordName))
            #expect(try SettingsSyncCoordinator.envelope(from: record) == envelope)
            record[field] = badValue
            #expect(throws: (any Error).self) { try SettingsSyncCoordinator.envelope(from: record) }
        }
    }

    @Test func cloudSyncContainsOnlyCustomRulesAndOneGlobalSwitch() throws {
        let domain = "TerminalHighlightCustom.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try store.prepare()
        let key = SettingsRecordKey(kind: .terminalHighlighting, id: "default")
        let initialEnvelope = try #require(try store.journal.envelope(for: key))
        #expect(initialEnvelope.payload == .terminalHighlighting(.init(rules: [])))
        let initialRecord = try SettingsSyncCoordinator.makeRecord(
            .init(envelope: initialEnvelope), recordID: .init(recordName: key.recordName))
        #expect(initialRecord["ruleCount"] as? Int == 0)
        #expect(initialRecord["ruleIDs"] == nil)
        #expect(initialRecord["ruleEnabled"] == nil)

        let custom = TerminalHighlightRule(name: "Remote", pattern: "REMOTE", backgroundColor: .yellow)
        let remote = TerminalHighlightPreferences(isEnabled: false, rules: [custom])
        let envelope = SettingsEnvelope(
            key: key, version: .next(after: initialEnvelope.version, writerID: UUID()),
            payload: .terminalHighlighting(remote))
        let record = try SettingsSyncCoordinator.makeRecord(
            .init(envelope: envelope), recordID: .init(recordName: key.recordName))
        #expect(record["ruleIDs"] as? [String] == [custom.id.uuidString.lowercased()])
        #expect(record["ruleEnabled"] == nil)
        #expect(record["enabled"] as? Int == 0)
        let result = try store.applyRemote([SettingsSyncCoordinator.envelope(from: record)])
        #expect(result.snapshot.terminalHighlighting == remote)
        #expect(
            result.snapshot.terminalHighlighting.effectiveRules == TerminalHighlightPreferences.builtInRules + [custom])
        #expect(!result.needsUpload.contains(key))

        let deleted = SettingsEnvelope(
            key: key, version: .next(after: envelope.version, writerID: UUID()), isDeleted: true)
        let cleared = try store.applyRemote([deleted])
        #expect(cleared.snapshot.terminalHighlighting.rules.isEmpty)
        #expect(cleared.snapshot.terminalHighlighting.effectiveRules == TerminalHighlightPreferences.builtInRules)
    }

    private func writeVersion45Store(_ url: URL) throws {
        let schema = Schema(versionedSchema: TermindSchemaV45.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [.init("Termind", schema: schema, url: url, cloudKitDatabase: .none)])
        container.mainContext.insert(try PersistentTerminalPreferences(.init(copyOnSelect: true)))
        try container.mainContext.save()
    }

    private func saveUpgradedStore(_ url: URL, value: TerminalHighlightPreferences) throws {
        let container = try TermindPersistence.makeContainer(url: url)
        container.mainContext.insert(try PersistentTerminalHighlightPreferences(value))
        try container.mainContext.save()
    }
}

@MainActor private final class HighlightStore: TerminalHighlightPreferencesPersisting {
    var value = TerminalHighlightPreferences()
    var fails = false
    func loadTerminalHighlightPreferences() throws -> TerminalHighlightPreferences { value }
    func saveTerminalHighlightPreferences(_ value: TerminalHighlightPreferences) throws {
        if fails { throw CocoaError(.fileWriteUnknown) }
        self.value = value
    }
}
