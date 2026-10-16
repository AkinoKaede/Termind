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

    /// A selection record (including a tombstone) is the durable per-mode migration marker.
    /// Seeds use baseline clocks, so they can never beat an explicit choice from another device.
    func migrateTerminalThemes(_ preferences: TerminalPreferences) throws -> Set<SettingsRecordKey> {
        var changed = Set<SettingsRecordKey>()
        var library = try loadTerminalThemes()
        for isDark in [false, true] {
            let appearance: TerminalThemeAppearance = isDark ? .dark : .light
            let selectionKey = SettingsRecordKey(kind: .terminalThemeSelection, id: appearance.rawValue)
            guard library.selection(isDark: isDark) == nil, try journal.envelope(for: selectionKey) == nil else {
                continue
            }
            let base = isDark ? preferences.darkTheme : preferences.lightTheme
            let text = isDark ? preferences.darkCustomConfiguration : preferences.lightCustomConfiguration
            let enabled = isDark ? preferences.darkCustomEnabled : preferences.lightCustomEnabled
            let defaultBase = isDark ? "Termind Dark" : "Termind Light"
            // Fresh installations wait for legacy cloud settings instead of publishing an empty migration.
            guard enabled || !text.isEmpty || base != defaultBase else { continue }
            var selection = TerminalThemeSelection(
                appearance: appearance, builtInThemeName: base.isEmpty ? defaultBase : base)
            var payloads: [SettingsRecordPayload] = []
            if enabled || !text.isEmpty {
                let id = Self.legacyThemeID(appearance: appearance, base: base, text: text)
                let key = SettingsRecordKey(kind: .terminalCustomTheme, id: id.uuidString.lowercased())
                if try journal.envelope(for: key) == nil {
                    let theme = TerminalCustomTheme(
                        id: id, name: isDark ? "Custom Dark" : "Custom Light", appearance: appearance,
                        baseThemeName: selection.builtInThemeName, configuration: text)
                    library.themes.append(theme)
                    payloads.append(.terminalCustomTheme(theme))
                }
                if enabled { selection.customThemeID = id }
            }
            library.select(selection)
            payloads.append(.terminalThemeSelection(selection))
            for payload in payloads {
                let envelope = SettingsEnvelope(
                    key: payload.key, version: .baseline(writerID: try journal.state().installationID), payload: payload
                )
                context.insert(try PersistentAIConfigurationSyncEntry(envelope: envelope, needsUpload: true))
                changed.insert(payload.key)
            }
        }
        if !changed.isEmpty { try applyTerminalThemes(library) }
        return changed
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
