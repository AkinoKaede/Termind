// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CloudKit
import CryptoKit
import Foundation
import TermindDomain
import TermindPersistence

/// Frozen native-field contract. Journal JSON is deliberately not the cloud representation.
nonisolated enum TerminalThemeCloudRecordV1 {
    static let themeRecordType = "TerminalCustomThemeItem"
    static let selectionRecordType = "TerminalThemeSelectionItem"

    static func recordType(for kind: SettingsRecordKind) -> String? {
        switch kind {
        case .terminalCustomTheme: themeRecordType
        case .terminalThemeSelection: selectionRecordType
        default: nil
        }
    }

    static func write(_ envelope: SettingsEnvelope, into record: CKRecord, assetURL: () throws -> URL) throws {
        guard envelope.isValid, envelope.version.counter <= UInt64(Int64.max),
            record.recordType == recordType(for: envelope.key.kind),
            record.recordID.recordName == envelope.key.recordName
        else { throw SettingsSyncPersistenceError.invalidEnvelope(record.recordID.recordName) }
        CloudSyncRecordCoding.setMetadata(
            on: record, formatVersion: 1, kind: envelope.key.kind.rawValue, entityID: envelope.key.id,
            version: envelope.version, isDeleted: envelope.isDeleted)
        let fields =
            envelope.key.kind == .terminalCustomTheme
            ? ["name", "appearance", "baseThemeName", "configuration", "configurationAsset", "configurationHash"]
            : ["appearance", "selectionKind", "builtInThemeName", "customThemeID"]
        for field in fields { record[field] = nil }
        switch envelope.payload {
        case .terminalCustomTheme(let value):
            record["name"] = value.name as NSString
            record["appearance"] = value.appearance.rawValue as NSString
            record["baseThemeName"] = value.baseThemeName as NSString
            let data = Data(value.configuration.utf8)
            record["configurationHash"] = hash(data) as NSString
            if data.count > CloudSyncRecordCoding.inlinePayloadLimit {
                let url = try assetURL()
                try data.write(to: url, options: .atomic)
                record["configurationAsset"] = CKAsset(fileURL: url)
            } else {
                record["configuration"] = value.configuration as NSString
            }
        case .terminalThemeSelection(let value):
            record["appearance"] = value.appearance.rawValue as NSString
            record["selectionKind"] = (value.customThemeID == nil ? "builtin" : "custom") as NSString
            record["builtInThemeName"] = value.builtInThemeName as NSString
            record["customThemeID"] = value.customThemeID?.uuidString.lowercased() as NSString?
        case nil: break
        default: throw SettingsSyncPersistenceError.invalidEnvelope(record.recordID.recordName)
        }
    }

    static func read(_ record: CKRecord) throws -> SettingsEnvelope {
        let invalid = SettingsSyncPersistenceError.invalidEnvelope(record.recordID.recordName)
        guard let format = record["formatVersion"] as? NSNumber, format == NSNumber(value: format.intValue) else {
            throw invalid
        }
        guard format.intValue == 1 else { throw CloudSyncCompatibilityError.unsupportedFormat(format.intValue) }
        guard let key = SettingsRecordKey(recordName: record.recordID.recordName),
            record.recordType == recordType(for: key.kind), record["kind"] as? String == key.kind.rawValue,
            record["entityID"] as? String == key.id,
            let date = record["modifiedAt"] as? Date,
            let counter = record["counter"] as? NSNumber, counter.int64Value >= 0,
            counter == NSNumber(value: counter.int64Value),
            let writer = record["writerID"] as? String, let writerID = UUID(uuidString: writer),
            let deleted = record["isDeleted"] as? NSNumber,
            deleted == NSNumber(value: 0) || deleted == NSNumber(value: 1)
        else { throw invalid }
        var payload: SettingsRecordPayload?
        if !deleted.boolValue {
            guard let rawAppearance = record["appearance"] as? String,
                let appearance = TerminalThemeAppearance(rawValue: rawAppearance)
            else { throw invalid }
            switch key.kind {
            case .terminalCustomTheme:
                guard let id = UUID(uuidString: key.id), let name = record["name"] as? String,
                    let base = record["baseThemeName"] as? String
                else { throw invalid }
                let data: Data
                if let text = record["configuration"] as? String {
                    guard record["configurationAsset"] == nil else { throw invalid }
                    data = Data(text.utf8)
                } else if record["configuration"] == nil,
                    let asset = record["configurationAsset"] as? CKAsset, let url = asset.fileURL
                {
                    data = try Data(contentsOf: url)
                } else {
                    throw invalid
                }
                guard record["configurationHash"] as? String == hash(data),
                    let text = String(data: data, encoding: .utf8)
                else { throw invalid }
                payload = .terminalCustomTheme(
                    .init(id: id, name: name, appearance: appearance, baseThemeName: base, configuration: text))
            case .terminalThemeSelection:
                guard appearance.rawValue == key.id, let base = record["builtInThemeName"] as? String,
                    let kind = record["selectionKind"] as? String
                else { throw invalid }
                let id: UUID?
                if kind == "custom" {
                    guard let raw = record["customThemeID"] as? String, let parsed = UUID(uuidString: raw) else {
                        throw invalid
                    }
                    id = parsed
                } else {
                    guard kind == "builtin", record["customThemeID"] == nil else { throw invalid }
                    id = nil
                }
                payload = .terminalThemeSelection(
                    .init(appearance: appearance, builtInThemeName: base, customThemeID: id))
            default: throw invalid
            }
        }
        let envelope = SettingsEnvelope(
            key: key, version: .init(modifiedAt: date, counter: counter.uint64Value, writerID: writerID),
            isDeleted: deleted.boolValue, payload: payload)
        guard envelope.isValid else { throw invalid }
        return envelope
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
