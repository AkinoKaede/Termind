// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@Suite @MainActor
struct TerminalFontPreferencesTests {
    @Test func defaultAndUnavailableFamiliesFollowThemeWithoutChangingSize() {
        #expect(TerminalFontPreferences() == .init(family: "", size: 12, sizeFollowsTheme: true))
        let selected = TerminalFontPreferences(family: "Missing Font", size: 19, sizeFollowsTheme: false)
        let resolved = selected.resolvingFamily(in: ["Menlo"])
        #expect(resolved == .init(family: "", size: 19, sizeFollowsTheme: false))
        #expect(selected.family == "Missing Font")
        #expect(selected.resolvingFamily(in: ["Missing Font"]) == selected)
    }

    @Test func upgradePreservesLocalTypographyAndIgnoresFutureLegacyRemoteValues() throws {
        let domain = "TerminalFontMigration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let row = try PersistentTerminalPreferences(.init())
        row.data = try legacyData(size: 19, followsTheme: false)
        container.mainContext.insert(row)
        try container.mainContext.save()
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try store.prepare()
        #expect(defaults.double(forKey: SettingsKey.terminalFontSize) == 19)
        #expect(!defaults.bool(forKey: SettingsKey.terminalFontFollowTheme))

        let legacy = try JSONDecoder().decode(TerminalPreferences.self, from: legacyData(size: 30, followsTheme: true))
        var remote = legacy
        remote.lightTheme = "GitHub Light"
        let payload = SettingsRecordPayload.terminal(remote)
        let envelope = SettingsEnvelope(
            key: payload.key, version: .next(after: nil, writerID: UUID(), now: .now), payload: payload)
        _ = try store.applyRemote([envelope])
        try store.prepare()
        #expect(try store.loadTerminal().lightTheme == "GitHub Light")
        #expect(defaults.double(forKey: SettingsKey.terminalFontSize) == 19)
        #expect(!defaults.bool(forKey: SettingsKey.terminalFontFollowTheme))
    }

    @Test func existingDeviceDefaultsWinOverOldLocalBlob() throws {
        let domain = "TerminalFontDefaults.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(15.0, forKey: SettingsKey.terminalFontSize)
        defaults.set(true, forKey: SettingsKey.terminalFontFollowTheme)
        defaults.set("Menlo", forKey: SettingsKey.terminalFontFamily)
        try TerminalFontPreferences.migrateLegacySettings(
            from: legacyData(size: 23, followsTheme: false), defaults: defaults)
        #expect(defaults.double(forKey: SettingsKey.terminalFontSize) == 15)
        #expect(defaults.bool(forKey: SettingsKey.terminalFontFollowTheme))
        #expect(defaults.string(forKey: SettingsKey.terminalFontFamily) == "Menlo")
    }

    @Test func partialAndFreshDefaultsAreInitializedOnce() throws {
        let domain = "TerminalFontPartialDefaults.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(16.0, forKey: SettingsKey.terminalFontSize)
        try TerminalFontPreferences.migrateLegacySettings(
            from: legacyData(size: 23, followsTheme: false), defaults: defaults)
        #expect(defaults.double(forKey: SettingsKey.terminalFontSize) == 16)
        #expect(!defaults.bool(forKey: SettingsKey.terminalFontFollowTheme))
        defaults.removePersistentDomain(forName: domain)
        try TerminalFontPreferences.migrateLegacySettings(from: nil, defaults: defaults)
        try TerminalFontPreferences.migrateLegacySettings(
            from: legacyData(size: 23, followsTheme: false), defaults: defaults)
        #expect(defaults.double(forKey: SettingsKey.terminalFontSize) == 12)
        #expect(defaults.bool(forKey: SettingsKey.terminalFontFollowTheme))
    }

    @Test func twoDevicesKeepIndependentTypographyAcrossSyncAndRestart() throws {
        let names = ["TerminalFontSource.\(UUID())", "TerminalFontDestination.\(UUID())"]
        let sourceDefaults = try #require(UserDefaults(suiteName: names[0]))
        let destinationDefaults = try #require(UserDefaults(suiteName: names[1]))
        defer {
            sourceDefaults.removePersistentDomain(forName: names[0])
            destinationDefaults.removePersistentDomain(forName: names[1])
        }
        let sourceContainer = try TermindPersistence.makeContainer(inMemory: true)
        let destinationContainer = try TermindPersistence.makeContainer(inMemory: true)
        let source = SettingsSyncPersistence(context: sourceContainer.mainContext, defaults: sourceDefaults)
        let destination = SettingsSyncPersistence(
            context: destinationContainer.mainContext, defaults: destinationDefaults)
        try source.prepare()
        try destination.prepare()
        let originalEnvelopes = try source.journal.pendingEnvelopes()
        sourceDefaults.set("Menlo", forKey: SettingsKey.terminalFontFamily)
        sourceDefaults.set(18.0, forKey: SettingsKey.terminalFontSize)
        sourceDefaults.set(false, forKey: SettingsKey.terminalFontFollowTheme)
        destinationDefaults.set("Courier", forKey: SettingsKey.terminalFontFamily)
        destinationDefaults.set(22.0, forKey: SettingsKey.terminalFontSize)
        #expect(try source.journal.pendingEnvelopes() == originalEnvelopes)

        try source.saveTerminal(.init(lightTheme: "GitHub Light"))
        let records = try source.journal.pendingEnvelopes().filter { $0.key.kind == .terminal }
        _ = try destination.applyRemote(records)
        let restarted = SettingsSyncPersistence(
            context: destinationContainer.mainContext, defaults: destinationDefaults)
        try restarted.prepare()
        #expect(try restarted.loadTerminal().lightTheme == "GitHub Light")
        #expect(destinationDefaults.string(forKey: SettingsKey.terminalFontFamily) == "Courier")
        #expect(destinationDefaults.double(forKey: SettingsKey.terminalFontSize) == 22)
        #expect(destinationDefaults.bool(forKey: SettingsKey.terminalFontFollowTheme))
        #expect(sourceDefaults.string(forKey: SettingsKey.terminalFontFamily) == "Menlo")
        #expect(sourceDefaults.double(forKey: SettingsKey.terminalFontSize) == 18)
        #expect(!sourceDefaults.bool(forKey: SettingsKey.terminalFontFollowTheme))
        let encoded = try String(decoding: SettingsSyncCodec.encode(#require(records.first)), as: UTF8.self)
        for key in ["fontFamily", "fontSize", "fontFollowTheme"] { #expect(!encoded.contains(key)) }
    }

    @Test func legacyTypographyIsDiscardedWhenRecordsAreReencodedForUpload() throws {
        let preferences = try JSONDecoder().decode(
            TerminalPreferences.self, from: legacyData(size: 28, followsTheme: false))
        let payload = SettingsRecordPayload.terminal(preferences)
        let envelope = SettingsEnvelope(
            key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        let data = try SettingsSyncCodec.encode(envelope)
        let encoded = String(decoding: data, as: UTF8.self)
        #expect(!encoded.contains("fontSize"))
        #expect(!encoded.contains("fontFollowTheme"))
        #expect(try SettingsSyncCodec.decode(data) == envelope)
    }

    private func legacyData(size: Double, followsTheme: Bool) throws -> Data {
        let encoded = try JSONEncoder().encode(TerminalPreferences())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["fontSize"] = size
        object["fontFollowTheme"] = followsTheme
        return try JSONSerialization.data(withJSONObject: object)
    }
}
