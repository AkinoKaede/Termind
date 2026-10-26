// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@Suite @MainActor
struct TerminalMousePreferencesTests {
    @Test func mousePreferencesDefaultOffAndPersistIndependentlyOnEachDevice() throws {
        let first = try makeDefaults()
        let second = try makeDefaults()
        defer {
            first.defaults.removePersistentDomain(forName: first.name)
            second.defaults.removePersistentDomain(forName: second.name)
        }
        let model = TerminalExperienceSettingsModel(defaults: first.defaults)
        #expect(!model.preferences.copyOnSelect)
        #expect(!model.preferences.pasteOnRightClick)
        model.set(true, for: \.copyOnSelect)
        #expect(model.preferences.copyOnSelect)
        #expect(!model.preferences.pasteOnRightClick)
        model.set(true, for: \.pasteOnRightClick)
        model.set(false, for: \.copyOnSelect)
        let reopened = TerminalExperienceSettingsModel(defaults: first.defaults)
        #expect(!reopened.preferences.copyOnSelect)
        #expect(reopened.preferences.pasteOnRightClick)
        let other = TerminalExperienceSettingsModel(defaults: second.defaults)
        #expect(!other.preferences.copyOnSelect)
        #expect(!other.preferences.pasteOnRightClick)
    }

    @Test(arguments: [nil, false, true] as [Bool?], [nil, false, true] as [Bool?])
    func upgradePreservesDefaultsAndFillsOnlyMissingKeys(existingCopy: Bool?, existingPaste: Bool?) throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        if let existingCopy {
            fixture.defaults.set(existingCopy, forKey: SettingsKey.terminalCopyOnSelect)
        }
        if let existingPaste {
            fixture.defaults.set(existingPaste, forKey: SettingsKey.terminalPasteOnRightClick)
        }
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let row = try PersistentTerminalPreferences(.init())
        row.data = try legacyData(copy: true, paste: true)
        container.mainContext.insert(row)
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: fixture.defaults)
        try store.prepare()
        let model = TerminalExperienceSettingsModel(defaults: fixture.defaults)
        #expect(model.preferences.copyOnSelect == (existingCopy ?? true))
        #expect(model.preferences.pasteOnRightClick == (existingPaste ?? true))

        model.set(false, for: \.copyOnSelect)
        model.set(false, for: \.pasteOnRightClick)
        try store.prepare()
        let reopened = TerminalExperienceSettingsModel(defaults: fixture.defaults)
        #expect(!reopened.preferences.copyOnSelect)
        #expect(!reopened.preferences.pasteOnRightClick)
    }

    @Test func legacyLocalValuesSurviveRewritingAndReopeningTheStore() throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mouse.store")
        try autoreleasepool {
            let container = try TermindPersistence.makeContainer(url: url)
            let row = try PersistentTerminalPreferences(.init())
            row.data = try legacyData(copy: true, paste: false)
            container.mainContext.insert(row)
            try container.mainContext.save()
        }
        try autoreleasepool {
            let container = try TermindPersistence.makeContainer(url: url)
            let store = SettingsSyncPersistence(context: container.mainContext, defaults: fixture.defaults)
            try store.prepare()
            try store.saveTerminal(.init(shellIntegration: false))
        }
        try autoreleasepool {
            let container = try TermindPersistence.makeContainer(url: url)
            let store = SettingsSyncPersistence(context: container.mainContext, defaults: fixture.defaults)
            try store.prepare()
            let model = TerminalExperienceSettingsModel(defaults: fixture.defaults)
            #expect(model.preferences.copyOnSelect)
            #expect(!model.preferences.pasteOnRightClick)
            #expect(try !store.loadTerminal().shellIntegration)
        }
    }

    @Test(arguments: [false, true])
    func missingLegacyFieldsAndFreshInstallsDefaultOff(hasLocalRow: Bool) throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let container = try TermindPersistence.makeContainer(inMemory: true)
        if hasLocalRow {
            container.mainContext.insert(try PersistentTerminalPreferences(.init(shellIntegration: false)))
        }
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: fixture.defaults)
        try store.prepare()
        #expect(fixture.defaults.object(forKey: SettingsKey.terminalCopyOnSelect) as? Bool == false)
        #expect(fixture.defaults.object(forKey: SettingsKey.terminalPasteOnRightClick) as? Bool == false)
    }

    @Test func mouseEditsNeverUploadAndLegacyRemoteSettingsCannotOverwriteLocalChoices() throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: fixture.defaults)
        try store.prepare()
        let pending = try store.journal.pendingEnvelopes()
        var recordedChanges = 0
        store.didRecordChanges = { _ in recordedChanges += 1 }
        let model = TerminalExperienceSettingsModel(defaults: fixture.defaults)
        model.set(true, for: \.copyOnSelect)
        model.set(true, for: \.pasteOnRightClick)
        model.set(false, for: \.pasteOnRightClick)
        #expect(try store.journal.pendingEnvelopes() == pending)
        #expect(recordedChanges == 0)

        let data =
            Data(#"{"terminal":{"_0":"#.utf8)
            + (try legacyData(copy: false, paste: true)) + Data("}}".utf8)
        let payload = try JSONDecoder().decode(SettingsRecordPayload.self, from: data)
        let envelope = SettingsEnvelope(
            key: payload.key, version: .next(after: nil, writerID: UUID(), now: .distantFuture), payload: payload)
        _ = try store.applyRemote([envelope])
        #expect(try store.loadTerminal().lightTheme == "GitHub Light")
        #expect(try !store.loadTerminal().shellIntegration)
        try expectNoMouseFields(store.loadTerminal())
        expectLocalChoices(fixture.defaults)

        let settings = TerminalSettingsModel(persistence: store)
        #expect(settings.set(true, for: \.shellIntegration))
        let outgoing = try #require(try store.journal.pendingEnvelopes().first { $0.key.kind == .terminal })
        guard case .terminal(let terminal) = outgoing.payload else {
            Issue.record("Expected terminal preferences")
            return
        }
        #expect(terminal.shellIntegration)
        #expect(terminal.lightTheme == "GitHub Light")
        try expectNoMouseFields(terminal)

        _ = try store.applyRemote([], deletions: [payload.key])
        expectLocalChoices(fixture.defaults)
        _ = try store.purgeCloudCache(
            scope: .init(container: "test", environment: "test", account: "test", zone: "settings", owner: "test"))
        expectLocalChoices(fixture.defaults)
    }

    private func expectLocalChoices(_ defaults: UserDefaults) {
        let reopened = TerminalExperienceSettingsModel(defaults: defaults)
        #expect(reopened.preferences.copyOnSelect)
        #expect(!reopened.preferences.pasteOnRightClick)
    }

    private func expectNoMouseFields(_ value: TerminalPreferences) throws {
        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(json["copyOnSelect"] == nil)
        #expect(json["pasteOnRightClick"] == nil)
    }

    private func legacyData(copy: Bool, paste: Bool) throws -> Data {
        var json = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(TerminalPreferences(lightTheme: "GitHub Light", shellIntegration: false)))
                as? [String: Any])
        json["copyOnSelect"] = copy
        json["pasteOnRightClick"] = paste
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func makeDefaults() throws -> (name: String, defaults: UserDefaults) {
        let name = "TerminalMouse.\(UUID())"
        return (name, try #require(UserDefaults(suiteName: name)))
    }
}
