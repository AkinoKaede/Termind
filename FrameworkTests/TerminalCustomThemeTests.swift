// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CloudKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import Testing

@Suite @MainActor
struct TerminalCustomThemeTests {
    @Test func copyingPreservesThemeContentAndTheDifferentDraftBaselines() {
        let original = TerminalCustomTheme(
            name: "Original", appearance: .both, baseThemeName: "Termind Light",
            configuration: "background = 123456")
        let copy = original.copy(named: "Original Copy")
        #expect(copy.id != original.id)
        #expect(copy.name == "Original Copy")
        #expect(copy.appearance == .both && copy.baseThemeName == "Termind Light")
        #expect(copy.configuration == "background = 123456")
        let newDraft = TerminalCustomThemeDraft(copy, isNew: true)
        #expect(newDraft.isNew && !newDraft.isDirty)
        #expect(newDraft.original == copy)
        let recovered = TerminalCustomThemeDraft(original, isNew: false)
        recovered.value.configuration = "background = ABCDEF"
        recovered.makeCopy(name: "Recovered")
        #expect(recovered.isNew && recovered.isDirty)
        #expect(recovered.original == original)
        #expect(recovered.id != original.id && recovered.id != copy.id)
        #expect(recovered.value.configuration == "background = ABCDEF")
        #expect(recovered.value.appearance == .both && recovered.value.baseThemeName == "Termind Light")
        let model = TerminalSettingsModel()
        #expect(model.saveCustomTheme(original, isNew: true))
        #expect(newDraft.save(in: model))
        #expect(recovered.save(in: model))
        #expect(!recovered.isNew && !recovered.isDirty)
        #expect(model.themeLibrary.themes.first { $0.id == original.id } == original)
    }

    @Test func choicesAreIndependentAndDeletingAnActiveThemeRestoresBothFallbacks() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = TerminalSettingsModel(persistence: fixture.store)
        let first = theme("First")
        let second = theme("Second", appearance: .dark)
        #expect(model.saveCustomTheme(first, isNew: true))
        #expect(model.saveCustomTheme(second, isNew: true))
        #expect(model.themeLibrary.selections.isEmpty)
        #expect(model.selectTheme(named: "GitHub Light", isDark: false))
        #expect(model.selectCustomTheme(id: first.id, isDark: false))
        #expect(model.themeLibrary.selectedTheme(isDark: true) == nil)
        #expect(!model.selectCustomTheme(id: second.id, isDark: false))
        #expect(model.selectCustomTheme(id: first.id, isDark: true))
        #expect(model.deleteCustomTheme(id: first.id))
        #expect(model.themeLibrary.selection(isDark: false)?.builtInThemeName == "GitHub Light")
        #expect(model.themeLibrary.selection(isDark: false)?.customThemeID == nil)
        #expect(model.themeLibrary.selection(isDark: true)?.customThemeID == nil)
        #expect(try fixture.store.loadTerminalThemes().themes == [second])
    }

    @Test func draftsDoNotApplyUntilSavedAndCannotResurrectDeletedThemes() {
        let model = TerminalSettingsModel()
        let original = theme("Personal")
        #expect(model.saveCustomTheme(original, isNew: true))
        let draft = TerminalCustomThemeDraft(original, isNew: false)
        draft.value.configuration = "background = 123456"
        #expect(model.themeLibrary.themes.first?.configuration == "")
        var remote = original
        remote.name = "Renamed remotely"
        model.applyRemoteThemes(.init(themes: [remote]))
        draft.refresh(from: model)
        #expect(draft.value.name == original.name)
        #expect(draft.save(in: model))
        #expect(!draft.isDirty)
        #expect(model.themeLibrary.themes.first?.configuration == "background = 123456")
        model.applyRemoteThemes(.init())
        draft.value.configuration = "background = ABCDEF"
        #expect(draft.isDeleted(in: model))
        #expect(!draft.save(in: model))
        draft.makeCopy(name: "Recovered")
        #expect(draft.id != original.id)
        #expect(draft.save(in: model))
        #expect(model.themeLibrary.themes.first?.name == "Recovered")
    }

    @Test func changingApplicabilityRepairsOnlyTheUnsupportedSelection() {
        let model = TerminalSettingsModel()
        var value = theme("Both")
        #expect(model.saveCustomTheme(value, isNew: true))
        #expect(model.selectCustomTheme(id: value.id, isDark: false))
        #expect(model.selectCustomTheme(id: value.id, isDark: true))
        value.appearance = .light
        #expect(model.saveCustomTheme(value, isNew: false))
        #expect(model.themeLibrary.selectedTheme(isDark: false)?.id == value.id)
        #expect(model.themeLibrary.selection(isDark: true)?.customThemeID == nil)
    }

    @Test func failedLibraryWriteLeavesTheModelAndDraftUntouched() {
        let store = FailingThemeStore()
        let model = TerminalSettingsModel(persistence: store)
        let draft = TerminalCustomThemeDraft(theme("New"), isNew: true)
        draft.value.configuration = "foreground = 123456"
        #expect(!draft.save(in: model))
        #expect(draft.isDirty)
        #expect(draft.isNew)
        #expect(model.themeLibrary.themes.isEmpty)
        #expect(model.storageError != nil)
        store.fails = false
        #expect(draft.save(in: model))
        #expect(model.themeLibrary.themes.first?.configuration == "foreground = 123456")
        #expect(model.storageError == nil)
    }

    @Test func legacyCloudImportUsesStableIDsAndDoesNotRepeat() throws {
        let first = try Fixture()
        let second = try Fixture()
        defer {
            first.cleanUp()
            second.cleanUp()
        }
        let payload = SettingsRecordPayload.terminal(
            .init(
                darkCustomEnabled: true, darkCustomConfiguration: "background = 123456",
                lightCustomConfiguration: "foreground = ABCDEF"))
        let envelope = SettingsEnvelope(
            key: payload.key, version: .init(modifiedAt: .now, counter: 0, writerID: UUID()), payload: payload)
        for fixture in [first, second] {
            let imported = try fixture.store.applyRemote([envelope]).snapshot.terminalThemes
            #expect(imported.themes.count == 2)
            #expect(imported.selectedTheme(isDark: true)?.configuration == "background = 123456")
            #expect(imported.selectedTheme(isDark: false) == nil)
            _ = try fixture.store.applyRemote([envelope])
            try fixture.store.prepare()
            #expect(try fixture.store.loadTerminalThemes().themes.count == 2)
            let seeds = try fixture.store.journal.pendingEnvelopes().filter {
                $0.key.kind == .terminalCustomTheme || $0.key.kind == .terminalThemeSelection
            }
            #expect(seeds.allSatisfy { $0.version.modifiedAt == VaultVersion.baselineDate })
        }
        #expect(try first.store.loadTerminalThemes() == second.store.loadTerminalThemes())
    }

    @Test(arguments: ["custom", "builtIn", "default"])
    func acceptedLegacyWinnerReconcilesUntouchedSeeds(_ kind: String) throws {
        let old = TerminalPreferences(
            darkTheme: "Old Dark", darkCustomEnabled: kind != "builtIn",
            darkCustomConfiguration: kind == "builtIn" ? "" : "background = 112233")
        let fixture = try Fixture(legacy: old)
        let fresh = try Fixture()
        defer {
            fixture.cleanUp()
            fresh.cleanUp()
        }
        let seeded = try fixture.store.loadTerminalThemes()
        let winner =
            kind == "default"
            ? TerminalPreferences()
            : TerminalPreferences(
                darkTheme: "New Dark", darkCustomEnabled: kind == "custom",
                darkCustomConfiguration: kind == "custom" ? "background = ABCDEF" : "")
        let envelope = legacyEnvelope(winner)
        let result = try fixture.store.applyRemote([envelope])
        let library = result.snapshot.terminalThemes
        #expect(result.acceptedKeys == [envelope.key])
        #expect(library.selection(isDark: true)?.builtInThemeName == winner.darkTheme)
        #expect(library.selectedTheme(isDark: true)?.configuration == (kind == "custom" ? "background = ABCDEF" : nil))
        #expect(library.selection(isDark: false) == nil)
        #expect(Set(seeded.themes).isSubset(of: Set(library.themes)))
        let selectionKey = SettingsRecordKey(kind: .terminalThemeSelection, id: "dark")
        #expect(result.needsUpload.contains(selectionKey))
        #expect(try fixture.store.journal.envelope(for: selectionKey)?.version.modifiedAt == VaultVersion.baselineDate)
        if kind == "custom" {
            let independentlyImported = try fresh.store.applyRemote([envelope]).snapshot.terminalThemes
            #expect(library.selectedTheme(isDark: true)?.id == independentlyImported.selectedTheme(isDark: true)?.id)
        }
        _ = try fixture.store.applyRemote([envelope])
        try fixture.store.prepare()
        #expect(try fixture.store.loadTerminalThemes() == library)
        let rows = try fixture.container.mainContext.fetch(FetchDescriptor<PersistentAIConfigurationSyncEntry>())
        #expect(rows.filter { $0.recordName == selectionKey.recordName }.count == 1)

        let rejected = try fixture.store.applyRemote([legacyEnvelope(old, time: 50)])
        #expect(rejected.acceptedKeys.isEmpty)
        #expect(rejected.snapshot.terminalThemes == library)
        let unrelated = SettingsRecordPayload.ssh(.init())
        _ = try fixture.store.applyRemote([
            SettingsEnvelope(
                key: unrelated.key, version: .init(modifiedAt: .now, counter: 0, writerID: UUID()), payload: unrelated)
        ])
        #expect(try fixture.store.loadTerminalThemes() == library)
    }

    @Test(arguments: ["selection", "edit", "selectionTombstone", "themeTombstone"])
    func nativeChangesProtectOnlyTheirAppearanceFromLegacyReconciliation(_ change: String) throws {
        let old = TerminalPreferences(
            darkCustomEnabled: true, lightCustomEnabled: true,
            darkCustomConfiguration: "background = 112233", lightCustomConfiguration: "background = DDEEFF")
        let fixture = try Fixture(legacy: old)
        defer { fixture.cleanUp() }
        var library = try fixture.store.loadTerminalThemes()
        let darkTheme = try #require(library.selectedTheme(isDark: true))
        let themeKey = SettingsRecordPayload.terminalCustomTheme(darkTheme).key
        let selectionKey = SettingsRecordKey(kind: .terminalThemeSelection, id: "dark")
        switch change {
        case "selection":
            library.select(.init(appearance: .dark, builtInThemeName: "Explicit Dark"))
            try fixture.store.saveTerminalThemes(library)
        case "edit":
            let index = try #require(library.themes.firstIndex { $0.id == darkTheme.id })
            library.themes[index].configuration = "background = 778899"
            try fixture.store.saveTerminalThemes(library)
        case "selectionTombstone":
            _ = try fixture.store.applyRemote([], deletions: [selectionKey])
        default:
            _ = try fixture.store.applyRemote([], deletions: [themeKey])
        }
        let protected = try fixture.store.loadTerminalThemes()
        let selectionBefore = try fixture.store.journal.envelope(for: selectionKey)
        let themeBefore = try fixture.store.journal.envelope(for: themeKey)
        let winner = TerminalPreferences(
            darkCustomEnabled: true, lightCustomEnabled: true,
            darkCustomConfiguration: "background = 445566", lightCustomConfiguration: "background = AABBCC")
        let result = try fixture.store.applyRemote([legacyEnvelope(winner)])
        #expect(result.snapshot.terminalThemes.selection(isDark: true) == protected.selection(isDark: true))
        #expect(result.snapshot.terminalThemes.selectedTheme(isDark: true) == protected.selectedTheme(isDark: true))
        #expect(result.snapshot.terminalThemes.selectedTheme(isDark: false)?.configuration == "background = AABBCC")
        #expect(try fixture.store.journal.envelope(for: selectionKey) == selectionBefore)
        #expect(try fixture.store.journal.envelope(for: themeKey) == themeBefore)
        #expect(!result.needsUpload.contains(selectionKey))
        #expect(!result.snapshot.terminalThemes.themes.contains { $0.configuration == "background = 445566" })
        try fixture.store.prepare()
        #expect(try fixture.store.loadTerminalThemes() == result.snapshot.terminalThemes)
    }

    @Test func legacyReconciliationDoesNotReviveAnEarlierDeletedImportedTheme() throws {
        let old = TerminalPreferences(darkCustomEnabled: true, darkCustomConfiguration: "background = 112233")
        let fixture = try Fixture(legacy: old)
        defer { fixture.cleanUp() }
        let original = try #require(try fixture.store.loadTerminalThemes().selectedTheme(isDark: true))
        let replacement = TerminalPreferences(darkCustomEnabled: true, darkCustomConfiguration: "background = 445566")
        _ = try fixture.store.applyRemote([legacyEnvelope(replacement)])
        let key = SettingsRecordPayload.terminalCustomTheme(original).key
        _ = try fixture.store.applyRemote([], deletions: [key])
        let tombstone = try fixture.store.journal.envelope(for: key)
        let result = try fixture.store.applyRemote([legacyEnvelope(old, time: 200)])
        #expect(!result.snapshot.terminalThemes.themes.contains { $0.id == original.id })
        #expect(result.snapshot.terminalThemes.selectedTheme(isDark: true) == nil)
        #expect(try fixture.store.journal.envelope(for: key) == tombstone)
        #expect(!result.needsUpload.contains(key))
    }

    @Test(arguments: [false, true])
    func nativeRecordsAcceptedWithLegacySettingsKeepPrecedence(_ editsTheme: Bool) throws {
        let old = TerminalPreferences(darkCustomEnabled: true, darkCustomConfiguration: "background = 112233")
        let fixture = try Fixture(legacy: old)
        defer { fixture.cleanUp() }
        let library = try fixture.store.loadTerminalThemes()
        let native: SettingsEnvelope
        if editsTheme {
            var value = try #require(library.selectedTheme(isDark: true))
            value.configuration = "background = 778899"
            let payload = SettingsRecordPayload.terminalCustomTheme(value)
            native = SettingsEnvelope(
                key: payload.key, version: .init(modifiedAt: .now, counter: 0, writerID: UUID()), payload: payload)
        } else {
            let payload = SettingsRecordPayload.terminalThemeSelection(try #require(library.selection(isDark: true)))
            native = SettingsEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        }
        let result = try fixture.store.applyRemote([
            legacyEnvelope(.init(darkCustomEnabled: true, darkCustomConfiguration: "background = ABCDEF")), native,
        ])
        #expect(result.acceptedKeys.contains(native.key))
        #expect(try fixture.store.journal.envelope(for: native.key) == native)
        #expect(result.snapshot.terminalThemes.selection(isDark: true) == library.selection(isDark: true))
        #expect(
            result.snapshot.terminalThemes.selectedTheme(isDark: true)?.configuration
                == (editsTheme ? "background = 778899" : "background = 112233"))
        #expect(result.snapshot.terminalThemes.themes.count == 1)
    }

    @Test func unrelatedRemoteTrafficDoesNotMigrateLocallyChangedLegacyPreferences() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.store.saveTerminal(.init(darkCustomEnabled: true, darkCustomConfiguration: "background = 112233"))
        let payload = SettingsRecordPayload.ssh(.init())
        _ = try fixture.store.applyRemote([
            SettingsEnvelope(
                key: payload.key, version: .init(modifiedAt: .now, counter: 0, writerID: UUID()), payload: payload)
        ])
        #expect(try fixture.store.loadTerminalThemes() == TerminalThemeLibrary())
    }

    @Test(arguments: [false, true])
    func reconciledBaselineSelectionReachesAnotherDeviceWithoutOverridingExplicitChoices(_ includeLegacy: Bool) throws {
        let source = try Fixture(legacy: .init(darkTheme: "Old Dark"))
        let destination = try Fixture()
        defer {
            source.cleanUp()
            destination.cleanUp()
        }
        _ = try destination.store.applyRemote(source.store.journal.pendingEnvelopes())
        let key = SettingsRecordKey(kind: .terminalThemeSelection, id: "dark")
        let old = try #require(try source.store.journal.envelope(for: key))
        let legacy = legacyEnvelope(.init(darkTheme: "New Dark"))
        _ = try source.store.applyRemote([legacy])
        let reconciled = try #require(try source.store.journal.envelope(for: key))
        #expect(reconciled.version == old.version)
        #expect(reconciled.payload != old.payload)
        let incoming = includeLegacy ? [legacy, reconciled] : [reconciled]
        let received = try destination.store.applyRemote(incoming)
        #expect(received.acceptedKeys.contains(key))
        #expect(received.snapshot.terminalThemes.selection(isDark: true)?.builtInThemeName == "New Dark")
        #expect(try destination.store.journal.envelope(for: key) == reconciled)
        var library = try destination.store.loadTerminalThemes()
        library.select(.init(appearance: .dark, builtInThemeName: "Explicit Dark"))
        try destination.store.saveTerminalThemes(library)
        let explicit = try destination.store.journal.envelope(for: key)
        _ = try destination.store.applyRemote([old, reconciled])
        #expect(try destination.store.journal.envelope(for: key) == explicit)
        #expect(try destination.store.loadTerminalThemes() == library)
    }

    @Test func legacySeedReconciliationRollsBackJournalProjectionAndUploadIntent() throws {
        let fixture = try Fixture(
            legacy: .init(darkCustomEnabled: true, darkCustomConfiguration: "background = 112233"))
        defer { fixture.cleanUp() }
        for envelope in try fixture.store.journal.pendingEnvelopes() {
            try fixture.store.journal.markUploaded(envelope.key, version: envelope.version)
        }
        try fixture.container.mainContext.save()
        let library = try fixture.store.loadTerminalThemes()
        let preferences = try fixture.store.loadTerminal()
        let before = try journalContents(fixture.container.mainContext)
        let pending = try fixture.store.journal.pendingEnvelopes()
        let winner = legacyEnvelope(.init(darkCustomEnabled: true, darkCustomConfiguration: "background = ABCDEF"))
        #expect(throws: (any Error).self) {
            try fixture.store.applyRemote([winner], beforeSave: { throw CocoaError(.fileWriteNoPermission) })
        }
        #expect(try fixture.store.loadTerminalThemes() == library)
        #expect(try fixture.store.loadTerminal() == preferences)
        #expect(try journalContents(fixture.container.mainContext) == before)
        #expect(try fixture.store.journal.pendingEnvelopes() == pending)
        #expect(TerminalPreferences(defaults: fixture.defaults) == preferences)
        let result = try fixture.store.applyRemote([winner])
        #expect(result.snapshot.terminalThemes.selectedTheme(isDark: true)?.configuration == "background = ABCDEF")
    }

    @Test func reconciledLegacySeedsRetainStableIDsAndContinueFollowingWinnersAfterReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ThemeReconciliation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "store.sqlite")
        let domain = "ThemeReconciliation-\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let winner = legacyEnvelope(.init(darkCustomEnabled: true, darkCustomConfiguration: "background = ABCDEF"))
        var retained = TerminalThemeLibrary()
        do {
            let container = try TermindPersistence.makeContainer(url: url)
            container.mainContext.insert(
                try PersistentTerminalPreferences(
                    .init(darkCustomEnabled: true, darkCustomConfiguration: "background = 112233")))
            let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
            try store.prepare()
            retained = try store.applyRemote([winner]).snapshot.terminalThemes
            #expect(retained.themes.count == 2)
        }
        do {
            let container = try TermindPersistence.makeContainer(url: url)
            let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
            try store.prepare()
            #expect(try store.loadTerminalThemes() == retained)
            let repeated = try store.applyRemote([winner])
            #expect(repeated.acceptedKeys.isEmpty)
            #expect(repeated.snapshot.terminalThemes == retained)
            let reset = try store.applyRemote([legacyEnvelope(.init(), time: 200)])
            #expect(reset.snapshot.terminalThemes.selectedTheme(isDark: true) == nil)
            #expect(reset.snapshot.terminalThemes.selection(isDark: true)?.builtInThemeName == "Termind Dark")
            #expect(reset.snapshot.terminalThemes.themes == retained.themes)
            retained = reset.snapshot.terminalThemes
        }
        let container = try TermindPersistence.makeContainer(url: url)
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try store.prepare()
        #expect(try store.loadTerminalThemes() == retained)
        let restored = try store.applyRemote([
            legacyEnvelope(
                .init(darkCustomEnabled: true, darkCustomConfiguration: "background = ABCDEF"), time: 300)
        ])
        #expect(restored.snapshot.terminalThemes.selectedTheme(isDark: true)?.configuration == "background = ABCDEF")
        #expect(restored.snapshot.terminalThemes.themes == retained.themes)
    }

    @Test func nativeBatchFailureRollsBackThemesAndSelectionTogether() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let custom = theme("Atomic")
        let payloads: [SettingsRecordPayload] = [
            .terminalCustomTheme(custom),
            .terminalThemeSelection(
                .init(appearance: .dark, builtInThemeName: "Termind Dark", customThemeID: custom.id)),
        ]
        let envelopes = payloads.map {
            SettingsEnvelope(key: $0.key, version: .init(modifiedAt: .now, counter: 0, writerID: UUID()), payload: $0)
        }
        #expect(throws: (any Error).self) {
            try fixture.store.applyRemote(envelopes, beforeSave: { throw CocoaError(.fileWriteNoPermission) })
        }
        #expect(try fixture.store.loadTerminalThemes() == TerminalThemeLibrary())
        for envelope in envelopes { #expect(try fixture.store.journal.envelope(for: envelope.key) == nil) }
    }

    @Test func nativeRecordsRoundTripWithoutJSONAndValidateTheirFields() throws {
        let value = theme("Native", configuration: "background = 112233\n# UTF-8: \u{4e3b}\u{9898}")
        let payloads: [SettingsRecordPayload] = [
            .terminalCustomTheme(value),
            .terminalThemeSelection(
                .init(appearance: .light, builtInThemeName: "Termind Light", customThemeID: value.id)),
            .terminalThemeSelection(.init(appearance: .dark, builtInThemeName: "Termind Dark")),
        ]
        for payload in payloads {
            let envelope = SettingsEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
            let record = try nativeRecord(envelope)
            #expect(record["payload"] == nil)
            #expect(record["payloadAsset"] == nil)
            #expect(record["payloadHash"] == nil)
            #expect(try SettingsSyncCoordinator.envelope(from: record) == envelope)
            record["appearance"] = "unknown" as NSString
            #expect(throws: (any Error).self) { try SettingsSyncCoordinator.envelope(from: record) }
            record["formatVersion"] = NSNumber(value: 99)
            #expect(throws: CloudSyncCompatibilityError.self) { try SettingsSyncCoordinator.envelope(from: record) }
        }
        let tombstone = SettingsEnvelope(
            key: payloads[0].key, version: .baseline(writerID: UUID()), isDeleted: true)
        let record = try nativeRecord(tombstone)
        #expect(record["name"] == nil)
        #expect(record["configuration"] == nil)
        #expect(try SettingsSyncCoordinator.envelope(from: record) == tombstone)
    }

    @Test func largeConfigurationUsesRawUTF8AssetAndRejectsCorruption() throws {
        let value = theme("Large", configuration: String(repeating: "# line\n", count: 100_001))
        let payload = SettingsRecordPayload.terminalCustomTheme(value)
        let envelope = SettingsEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        let record = try nativeRecord(envelope)
        let asset = try #require(record["configurationAsset"] as? CKAsset)
        let url = try #require(asset.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(record["configuration"] == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == value.configuration)
        #expect(try SettingsSyncCoordinator.envelope(from: record) == envelope)
        record["configurationHash"] = "corrupt" as NSString
        #expect(throws: (any Error).self) { try SettingsSyncCoordinator.envelope(from: record) }
    }

    @Test func selectionCanArriveBeforeThemeAndLegacyWritesDoNotEraseTheLibrary() throws {
        let source = try Fixture()
        let destination = try Fixture()
        defer {
            source.cleanUp()
            destination.cleanUp()
        }
        let model = TerminalSettingsModel(persistence: source.store)
        let value = theme("Synced")
        #expect(model.saveCustomTheme(value, isNew: true))
        #expect(model.selectCustomTheme(id: value.id, isDark: false))
        let entries = try source.store.journal.pendingEnvelopes()
        let choices = entries.filter { $0.key.kind == .terminalThemeSelection }
        let themes = entries.filter { $0.key.kind == .terminalCustomTheme }
        let pending = try destination.store.applyRemote(choices).snapshot.terminalThemes
        #expect(pending.selection(isDark: false)?.customThemeID == value.id)
        #expect(pending.selectedTheme(isDark: false) == nil)
        let resolved = try destination.store.applyRemote(themes).snapshot.terminalThemes
        #expect(resolved.selectedTheme(isDark: false)?.id == value.id)
        #expect(try !destination.store.journal.pendingEnvelopes().contains { $0.key.kind == .terminalCustomTheme })

        let legacy = SettingsRecordPayload.terminal(.init(lightTheme: "Other Legacy Theme"))
        let oldWriter = SettingsEnvelope(
            key: legacy.key, version: .init(modifiedAt: .distantFuture, counter: 0, writerID: UUID()), payload: legacy)
        let afterLegacy = try destination.store.applyRemote([oldWriter]).snapshot.terminalThemes
        #expect(afterLegacy == resolved)

        #expect(model.deleteCustomTheme(id: value.id))
        let deletion = try source.store.journal.pendingEnvelopes().filter {
            $0.key.kind == .terminalCustomTheme || $0.key.kind == .terminalThemeSelection
        }
        let removed = try destination.store.applyRemote(deletion).snapshot.terminalThemes
        #expect(removed.themes.isEmpty)
        #expect(removed.selection(isDark: false)?.customThemeID == nil)
        try destination.store.prepare()
        #expect(try destination.store.loadTerminalThemes().themes.isEmpty)
    }

    @Test func independentDeviceEditsMergePerThemeRatherThanReplacingTheWholeLibrary() throws {
        let first = try Fixture()
        let second = try Fixture()
        defer {
            first.cleanUp()
            second.cleanUp()
        }
        let a = theme("A")
        let b = theme("B")
        try first.store.saveTerminalThemes(.init(themes: [a, b]))
        _ = try second.store.applyRemote(first.store.journal.pendingEnvelopes())
        var left = try first.store.loadTerminalThemes()
        var right = try second.store.loadTerminalThemes()
        left.themes[left.themes.firstIndex(where: { $0.id == a.id })!].name = "A edited"
        right.themes[right.themes.firstIndex(where: { $0.id == b.id })!].name = "B edited"
        try first.store.saveTerminalThemes(left)
        try second.store.saveTerminalThemes(right)
        let leftChanges = try first.store.journal.pendingEnvelopes()
        let rightChanges = try second.store.journal.pendingEnvelopes()
        _ = try first.store.applyRemote(rightChanges)
        _ = try second.store.applyRemote(leftChanges)
        for fixture in [first, second] {
            let names = Set(try fixture.store.loadTerminalThemes().themes.map(\.name))
            #expect(names == ["A edited", "B edited"])
        }
    }

    @Test func historicalCustomConfigurationsMigrateOnceAndSurviveStoreReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ThemeMigration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "store.sqlite")
        let defaults = UserDefaults(suiteName: "ThemeMigration-\(UUID())")!
        let schema = Schema(versionedSchema: TermindSchemaV56.self)
        var old: ModelContainer? = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        old!.mainContext.insert(
            try PersistentTerminalPreferences(
                .init(
                    darkCustomEnabled: true, darkCustomConfiguration: "background = 123456",
                    lightCustomConfiguration: "foreground = ABCDEF")))
        try old!.mainContext.save()
        old = nil
        var retained: TerminalThemeLibrary?
        do {
            let container = try TermindPersistence.makeContainer(url: url)
            let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
            try store.prepare()
            retained = try store.loadTerminalThemes()
            #expect(retained?.themes.count == 2)
            #expect(retained?.selectedTheme(isDark: true)?.configuration == "background = 123456")
            #expect(retained?.selectedTheme(isDark: false) == nil)
            try store.prepare()
            #expect(try store.loadTerminalThemes() == retained)
        }
        let reopened = try TermindPersistence.makeContainer(url: url)
        let store = SettingsSyncPersistence(context: reopened.mainContext, defaults: defaults)
        try store.prepare()
        #expect(try store.loadTerminalThemes() == retained)
        let model = TerminalSettingsModel(persistence: store)
        for value in model.themeLibrary.themes { #expect(model.deleteCustomTheme(id: value.id)) }
        try store.prepare()
        #expect(try store.loadTerminalThemes().themes.isEmpty)
    }

    private func theme(
        _ name: String, appearance: TerminalThemeAppearance = .both, configuration: String = ""
    ) -> TerminalCustomTheme {
        .init(name: name, appearance: appearance, baseThemeName: "Termind Dark", configuration: configuration)
    }

    private func legacyEnvelope(_ preferences: TerminalPreferences, time: TimeInterval = 100) -> SettingsEnvelope {
        let payload = SettingsRecordPayload.terminal(preferences)
        return SettingsEnvelope(
            key: payload.key,
            version: .init(modifiedAt: Date(timeIntervalSince1970: time), counter: 0, writerID: UUID()),
            payload: payload)
    }

    private func journalContents(_ context: ModelContext) throws -> [String: Data] {
        Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<PersistentAIConfigurationSyncEntry>()).map {
                ($0.recordName, $0.envelopeData)
            })
    }

    private func nativeRecord(_ envelope: SettingsEnvelope) throws -> CKRecord {
        try SettingsSyncCoordinator.makeRecord(
            .init(envelope: envelope),
            recordID: .init(
                recordName: envelope.key.recordName,
                zoneID: .init(zoneName: SettingsSyncCoordinator.zoneName, ownerName: CKCurrentUserDefaultName)))
    }

    private struct Fixture {
        let container: ModelContainer
        let store: SettingsSyncPersistence
        let domain = "TerminalCustomThemeTests.\(UUID())"
        let defaults: UserDefaults
        init(legacy: TerminalPreferences? = nil) throws {
            container = try TermindPersistence.makeContainer(inMemory: true)
            defaults = UserDefaults(suiteName: domain)!
            if let legacy { container.mainContext.insert(try PersistentTerminalPreferences(legacy)) }
            store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
            try store.prepare()
        }
        func cleanUp() { defaults.removePersistentDomain(forName: domain) }
    }
}

@MainActor private final class FailingThemeStore: TerminalPreferencesPersisting {
    var fails = true
    var usesNativeTerminalThemes: Bool { true }
    func loadTerminal() throws -> TerminalPreferences { .init() }
    func saveTerminal(_ value: TerminalPreferences) throws {}
    func saveTerminalThemes(_ value: TerminalThemeLibrary) throws {
        if fails { throw CocoaError(.fileWriteNoPermission) }
    }
}
