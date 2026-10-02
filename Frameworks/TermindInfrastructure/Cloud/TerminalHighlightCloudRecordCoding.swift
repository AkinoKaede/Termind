import CloudKit
import Foundation
import TermindDomain
import TermindPersistence

/// Native CloudKit columns. Parallel arrays preserve rule order in one atomic record.
nonisolated enum TerminalHighlightCloudRecordCoding {
    private static let ruleFields = [
        "ruleIDs", "ruleNames", "rulePatterns", "ruleModes", "ruleCaseSensitive",
        "ruleForegroundColors", "ruleBackgroundColors",
    ]

    static func encode(_ envelope: SettingsEnvelope, into record: CKRecord) throws {
        guard envelope.isValid else { throw invalid(record) }
        guard !envelope.isDeleted, case .terminalHighlighting(let value) = envelope.payload else {
            record["enabled"] = nil
            record["ruleCount"] = nil
            for field in ruleFields { record[field] = nil }
            return
        }
        record["enabled"] = NSNumber(value: value.isEnabled)
        record["ruleCount"] = NSNumber(value: value.rules.count)
        // Empty lists are represented by an explicit count, not missing preferences.
        guard !value.rules.isEmpty else {
            for field in ruleFields { record[field] = nil }
            return
        }
        record["ruleIDs"] = value.rules.map { $0.id.uuidString.lowercased() } as NSArray
        record["ruleNames"] = value.rules.map(\.name) as NSArray
        record["rulePatterns"] = value.rules.map(\.pattern) as NSArray
        record["ruleModes"] = value.rules.map { $0.mode.rawValue } as NSArray
        record["ruleCaseSensitive"] = value.rules.map { NSNumber(value: $0.isCaseSensitive) } as NSArray
        record["ruleForegroundColors"] = value.rules.map { $0.color.rawValue } as NSArray
        record["ruleBackgroundColors"] = value.rules.map { $0.backgroundColor.rawValue } as NSArray
    }

    static func decode(_ record: CKRecord) throws -> SettingsEnvelope {
        let format = try integer(record["formatVersion"], record: record)
        if format > SettingsEnvelope.currentFormatVersion {
            throw CloudSyncCompatibilityError.unsupportedFormat(format)
        }
        let key = SettingsRecordKey(kind: .terminalHighlighting, id: "default")
        guard format == SettingsEnvelope.currentFormatVersion,
            record.recordID.recordName == key.recordName,
            record["kind"] as? String == key.kind.rawValue,
            record["entityID"] as? String == key.id,
            let date = record["modifiedAt"] as? Date,
            let writerText = record["writerID"] as? String, let writer = UUID(uuidString: writerText)
        else { throw invalid(record) }
        let counter = try integer(record["counter"], record: record)
        guard counter >= 0 else { throw invalid(record) }
        let deleted = try boolean(record["isDeleted"], record: record)
        var envelope = SettingsEnvelope(
            key: key, version: .init(modifiedAt: date, counter: UInt64(counter), writerID: writer), isDeleted: deleted)
        if deleted { return envelope }
        let enabled = try boolean(record["enabled"], record: record)
        let count = try integer(record["ruleCount"], record: record)
        guard (0...TerminalHighlightPreferences.maximumCustomRuleCount).contains(count) else { throw invalid(record) }
        if count == 0 {
            guard ruleFields.allSatisfy({ record[$0] == nil || (record[$0] as? NSArray)?.count == 0 }) else {
                throw invalid(record)
            }
            envelope.payload = .terminalHighlighting(.init(isEnabled: enabled, rules: []))
            return envelope
        }
        func strings(_ key: String) throws -> [String] {
            guard let values = record[key] as? [String], values.count == count else { throw invalid(record) }
            return values
        }
        func booleans(_ key: String) throws -> [Bool] {
            guard let values = record[key] as? [NSNumber], values.count == count else { throw invalid(record) }
            return try values.map { try boolean($0, record: record) }
        }
        let ids = try strings("ruleIDs")
        let names = try strings("ruleNames")
        let patterns = try strings("rulePatterns")
        let modes = try strings("ruleModes")
        let foregrounds = try strings("ruleForegroundColors")
        let backgrounds = try strings("ruleBackgroundColors")
        let cases = try booleans("ruleCaseSensitive")
        var rules: [TerminalHighlightRule] = []
        for index in 0..<count {
            guard let id = UUID(uuidString: ids[index]),
                let mode = TerminalHighlightRule.MatchMode(rawValue: modes[index]),
                let foreground = TagColor(rawValue: foregrounds[index]),
                let background = TagColor(rawValue: backgrounds[index])
            else { throw invalid(record) }
            rules.append(
                .init(
                    id: id, name: names[index], pattern: patterns[index], mode: mode,
                    isCaseSensitive: cases[index], color: foreground, backgroundColor: background))
        }
        envelope.payload = .terminalHighlighting(.init(isEnabled: enabled, rules: rules))
        guard envelope.isValid else { throw invalid(record) }
        return envelope
    }

    private static func integer(_ value: (any CKRecordValueProtocol)?, record: CKRecord) throws -> Int {
        guard let number = value as? NSNumber, number.doubleValue.isFinite,
            number.doubleValue >= 0, number.doubleValue < Double(Int64.max),
            number.doubleValue.rounded(.towardZero) == number.doubleValue
        else { throw invalid(record) }
        return number.intValue
    }

    private static func boolean(_ value: (any CKRecordValueProtocol)?, record: CKRecord) throws -> Bool {
        let number = try integer(value, record: record)
        guard number == 0 || number == 1 else { throw invalid(record) }
        return number == 1
    }

    private static func invalid(_ record: CKRecord) -> SettingsSyncPersistenceError {
        .invalidEnvelope(record.recordID.recordName)
    }
}
