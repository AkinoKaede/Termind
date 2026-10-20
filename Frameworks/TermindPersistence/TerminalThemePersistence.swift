// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentTerminalCustomTheme {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var appearance: String
    public var baseThemeName: String
    public var configuration: String

    public init(_ value: TerminalCustomTheme) {
        id = value.id
        name = value.name
        appearance = value.appearance.rawValue
        baseThemeName = value.baseThemeName
        configuration = value.configuration
    }

    public var value: TerminalCustomTheme {
        get throws {
            guard let mode = TerminalThemeAppearance(rawValue: appearance) else { throw CocoaError(.coderReadCorrupt) }
            return .init(
                id: id, name: name, appearance: mode, baseThemeName: baseThemeName, configuration: configuration)
        }
    }
}

@Model
public final class PersistentTerminalThemeSelection {
    @Attribute(.unique) public var appearance: String
    public var builtInThemeName: String
    public var customThemeID: UUID?

    public init(_ value: TerminalThemeSelection) {
        appearance = value.appearance.rawValue
        builtInThemeName = value.builtInThemeName
        customThemeID = value.customThemeID
    }

    public var value: TerminalThemeSelection {
        get throws {
            guard let mode = TerminalThemeAppearance(rawValue: appearance), mode != .both else {
                throw CocoaError(.coderReadCorrupt)
            }
            return .init(appearance: mode, builtInThemeName: builtInThemeName, customThemeID: customThemeID)
        }
    }
}

extension SettingsSyncPersistence {
    public var usesNativeTerminalThemes: Bool { true }
    public func loadTerminalThemes() throws -> TerminalThemeLibrary {
        let themes = try context.fetch(FetchDescriptor<PersistentTerminalCustomTheme>()).map { try $0.value }
        let selections = try context.fetch(FetchDescriptor<PersistentTerminalThemeSelection>()).map { try $0.value }
        return .init(
            themes: themes.sorted { $0.id.uuidString < $1.id.uuidString },
            selections: selections.sorted { $0.appearance.rawValue < $1.appearance.rawValue })
    }

    public func saveTerminalThemes(_ value: TerminalThemeLibrary) throws {
        guard value.themes.allSatisfy(\.isValid), value.selections.allSatisfy(\.isValid),
            Set(value.themes.map(\.id)).count == value.themes.count,
            Set(value.selections.map(\.appearance)).count == value.selections.count
        else { throw CocoaError(.coderInvalidValue) }
        try saveLocal { try applyTerminalThemes(value) }
    }

    func applyTerminalThemes(_ value: TerminalThemeLibrary) throws {
        let themes = try context.fetch(FetchDescriptor<PersistentTerminalCustomTheme>())
        let selections = try context.fetch(FetchDescriptor<PersistentTerminalThemeSelection>())
        for row in themes {
            guard let updated = value.themes.first(where: { $0.id == row.id }) else {
                context.delete(row)
                continue
            }
            row.name = updated.name
            row.appearance = updated.appearance.rawValue
            row.baseThemeName = updated.baseThemeName
            row.configuration = updated.configuration
        }
        for theme in value.themes where !themes.contains(where: { $0.id == theme.id }) {
            context.insert(PersistentTerminalCustomTheme(theme))
        }
        for row in selections {
            guard let updated = value.selections.first(where: { $0.appearance.rawValue == row.appearance }) else {
                context.delete(row)
                continue
            }
            row.builtInThemeName = updated.builtInThemeName
            row.customThemeID = updated.customThemeID
        }
        for selection in value.selections
        where !selections.contains(where: { $0.appearance == selection.appearance.rawValue }) {
            context.insert(PersistentTerminalThemeSelection(selection))
        }
    }

    /// Explicit choices and tombstones finish migration; untouched baseline seeds can follow
    /// a subsequently accepted legacy winner without claiming a new user-choice clock.
    func migrateTerminalThemes(
        _ preferences: TerminalPreferences, replacing previous: TerminalPreferences? = nil,
        preservingSelections: Set<SettingsRecordKey> = []
    ) throws -> Set<SettingsRecordKey> {
        var changed = Set<SettingsRecordKey>()
        var library = try loadTerminalThemes()
        for isDark in [false, true] {
            let appearance: TerminalThemeAppearance = isDark ? .dark : .light
            let selectionKey = SettingsRecordKey(kind: .terminalThemeSelection, id: appearance.rawValue)
            let existing = try journal.envelope(for: selectionKey)
            if existing != nil || library.selection(isDark: isDark) != nil {
                guard let previous, !preservingSelections.contains(selectionKey),
                    try isUntouchedLegacyThemeSeed(previous, isDark: isDark, selection: existing)
                else { continue }
            }
            let seed = Self.legacyThemeSeed(preferences, isDark: isDark)
            let base = isDark ? preferences.darkTheme : preferences.lightTheme
            let defaultBase = isDark ? "Termind Dark" : "Termind Light"
            // A fresh installation waits for legacy settings; a reconciled default stays a durable marker.
            guard existing != nil || seed.theme != nil || base != defaultBase else {
                continue
            }
            var payloads: [SettingsRecordPayload] = []
            if let theme = seed.theme {
                let payload = SettingsRecordPayload.terminalCustomTheme(theme)
                // An existing native edit or tombstone owns this deterministic ID.
                if try journal.envelope(for: payload.key) == nil {
                    library.themes.append(theme)
                    payloads.append(payload)
                }
            }
            let selectionPayload = SettingsRecordPayload.terminalThemeSelection(seed.selection)
            if existing?.payload != selectionPayload {
                library.select(seed.selection)
                payloads.append(selectionPayload)
            }
            for payload in payloads {
                try journal.storeMigrationSeed(payload)
                changed.insert(payload.key)
            }
        }
        if !changed.isEmpty { try applyTerminalThemes(library) }
        return changed
    }

    private func isUntouchedLegacyThemeSeed(
        _ preferences: TerminalPreferences, isDark: Bool, selection: SettingsEnvelope?
    ) throws -> Bool {
        let seed = Self.legacyThemeSeed(preferences, isDark: isDark)
        guard let selection, selection.version == .baseline(writerID: selection.version.writerID),
            !selection.isDeleted, selection.payload == .terminalThemeSelection(seed.selection)
        else { return false }
        if let theme = seed.theme {
            let payload = SettingsRecordPayload.terminalCustomTheme(theme)
            guard let envelope = try journal.envelope(for: payload.key),
                envelope.version == .baseline(writerID: envelope.version.writerID),
                !envelope.isDeleted, envelope.payload == payload
            else { return false }
        }
        return true
    }

    private nonisolated static func legacyThemeSeed(
        _ preferences: TerminalPreferences, isDark: Bool
    ) -> (selection: TerminalThemeSelection, theme: TerminalCustomTheme?) {
        let appearance: TerminalThemeAppearance = isDark ? .dark : .light
        let base = isDark ? preferences.darkTheme : preferences.lightTheme
        let text = isDark ? preferences.darkCustomConfiguration : preferences.lightCustomConfiguration
        let enabled = isDark ? preferences.darkCustomEnabled : preferences.lightCustomEnabled
        let defaultBase = isDark ? "Termind Dark" : "Termind Light"
        var selection = TerminalThemeSelection(
            appearance: appearance, builtInThemeName: base.isEmpty ? defaultBase : base)
        var theme: TerminalCustomTheme?
        if enabled || !text.isEmpty {
            let id = legacyThemeID(appearance: appearance, base: base, text: text)
            theme = TerminalCustomTheme(
                id: id, name: isDark ? "Custom Dark" : "Custom Light", appearance: appearance,
                baseThemeName: selection.builtInThemeName, configuration: text)
            if enabled { selection.customThemeID = id }
        }
        return (selection, theme)
    }

    private nonisolated static func legacyThemeID(
        appearance: TerminalThemeAppearance, base: String, text: String
    ) -> UUID {
        let seed = "termind-custom-theme-v1\u{0}\(appearance.rawValue)\u{0}\(base)\u{0}\(text)"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}
