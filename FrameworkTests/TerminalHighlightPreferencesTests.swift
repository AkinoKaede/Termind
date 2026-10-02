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
    @Test func ruleActionsPersistOrderAndKeepTheCommittedSnapshotAfterFailure() {
        let store = HighlightStore()
        let model = TerminalHighlightSettingsModel(persistence: store)
        let rules = (0..<4).map { TerminalHighlightRule(name: "Rule \($0)", pattern: "\($0)") }
        for rule in rules { #expect(model.upsert(rule)) }
        #expect(model.move(fromOffsets: IndexSet([0, 2]), toOffset: 4))
        #expect(model.preferences.rules.map(\.id) == [rules[1].id, rules[3].id, rules[0].id, rules[2].id])
        #expect(!model.canMove(rules[1].id, by: -1))
        #expect(model.move(rules[2].id, by: -1))
        #expect(model.delete(rules[3].id))
        #expect(model.preferences.rules.map(\.id) == [rules[1].id, rules[2].id, rules[0].id])
        let committed = model.preferences
        store.fails = true
        #expect(!model.delete(rules[0].id))
        #expect(!model.setEnabled(false))
        #expect(model.preferences == committed)
        #expect(store.value == committed)
        #expect(model.storageError != nil)
    }

    @Test func editingAndSavingUseTheSameInjectedPatternAndCapacityValidation() {
        let model = TerminalHighlightSettingsModel(validatePattern: { $0.pattern == "[" ? "Unclosed bracket" : nil })
        let invalid = TerminalHighlightRule(name: "Invalid", pattern: "[", mode: .regularExpression)
        #expect(model.validationIssue(for: invalid) == .invalidPattern("Unclosed bracket"))
        #expect(!model.upsert(invalid))
        #expect(model.failure == .validation(.invalidPattern("Unclosed bracket")))
        for index in 0..<TerminalHighlightPreferences.maximumCustomRuleCount {
            #expect(model.upsert(.init(name: "Rule \(index)", pattern: "value")))
        }
        #expect(!model.canAddRule)
        let extra = TerminalHighlightRule(name: "Extra", pattern: "value")
        #expect(model.validationIssue(for: extra) == .ruleLimit)
        #expect(!model.upsert(extra))
        #expect(model.failure == .validation(.ruleLimit))
        var existing = model.preferences.rules[0]
        existing.name = "Updated"
        #expect(model.validationIssue(for: existing) == nil)
        #expect(model.upsert(existing))
        #expect(model.failure == nil)
    }

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
            #expect(!model.upsert(edited))
        }
        #expect(model.setEnabled(false))
        #expect(!model.preferences.isEnabled)
        #expect(model.preferences.rules.isEmpty)
        #expect(model.preferences.effectiveRules == TerminalHighlightPreferences.builtInRules)
    }

    @Test func customRulesRemainEditableAndDeletable() {
        let model = TerminalHighlightSettingsModel()
        var rule = TerminalHighlightRule(name: "Custom", pattern: "hello", color: .none)
        #expect(!rule.isBuiltIn)
        #expect(model.upsert(rule))
        rule.name = "Edited"
        rule.pattern = "world"
        rule.backgroundColor = .pink
        #expect(model.upsert(rule))
        #expect(model.preferences.rules.last == rule)
        #expect(model.delete(rule.id))
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
        let model = TerminalHighlightSettingsModel(
            persistence: store, validatePattern: { $0.pattern == "[" ? "Invalid regex" : nil })
        store.fails = true
        #expect(!model.setEnabled(false))
        #expect(model.preferences == TerminalHighlightPreferences())
        #expect(model.storageError != nil)
        #expect(!model.upsert(.init(name: "Invalid", pattern: "[", mode: .regularExpression)))
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
