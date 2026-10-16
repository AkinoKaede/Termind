import CloudKit
import Foundation
import TermindDomain
import TermindPersistence

/// CloudKit field contract for History V2. Local journal serialization and
/// legacy Vault JSON are deliberately not the cloud protocol for these records.
/// Register another per-kind reader before changing a field's type or semantics.
nonisolated enum HistoryCloudRecordV2 {
    static func write(_ envelope: HistoryEnvelope, into record: CKRecord) throws {
        try SyncRecordFormats.history.validate(kind: envelope.key.kind.rawValue, version: envelope.formatVersion)
        guard envelope.formatVersion == 2, envelope.isValid, envelope.version.counter <= UInt64(Int64.max),
            record.recordType == envelope.key.kind.recordType, record.recordID.recordName == envelope.key.recordName
        else { throw VaultSyncPersistenceError.invalidEnvelope(envelope.key.recordName) }
        record["formatVersion"] = NSNumber(value: envelope.formatVersion)
        record["kind"] = envelope.key.kind.rawValue as NSString
        record["entityID"] = envelope.key.id.uuidString.lowercased() as NSString
        record["modifiedAt"] = envelope.version.modifiedAt as NSDate
        record["counter"] = NSNumber(value: envelope.version.counter)
        record["writerID"] = envelope.version.writerID.uuidString.lowercased() as NSString
        record["isDeleted"] = NSNumber(value: envelope.isDeleted)
        // Clear optional fields explicitly, including tombstones. A CKRecord restored
        // from system fields must never retain an old end time or live payload.
        let fields =
            envelope.key.kind == .device
            ? ["displayName"] : ["hostID", "connectionKind", "connectedAt", "endedAt", "sourceDeviceID"]
        for field in fields {
            record[field] = nil
        }
        switch envelope.payload {
        case .connectionHistory(let value):
            record["hostID"] = value.hostID.uuidString.lowercased() as NSString
            // Exhaustiveness forces a deliberate V1/V2 decision when domain kinds grow.
            switch value.kind {
            case .ssh: record["connectionKind"] = "ssh" as NSString
            case .telnet: record["connectionKind"] = "telnet" as NSString
            case .sftp: record["connectionKind"] = "sftp" as NSString
            case .mosh: record["connectionKind"] = "mosh" as NSString
            case .eternalTerminal: record["connectionKind"] = "eternalTerminal" as NSString
            }
            record["connectedAt"] = value.connectedAt as NSDate
            record["endedAt"] = value.endedAt as NSDate?
            record["sourceDeviceID"] = value.sourceDeviceID?.uuidString.lowercased() as NSString?
        case .device(let value): record["displayName"] = value.displayName as NSString
        case nil: break
        }
    }

    static func read(_ record: CKRecord) throws -> HistoryEnvelope {
        let invalid = VaultSyncPersistenceError.invalidEnvelope(record.recordID.recordName)
        guard let rawKind = record["kind"] as? String,
            let versionNumber = record["formatVersion"] as? NSNumber,
            versionNumber == NSNumber(value: versionNumber.intValue)
        else { throw invalid }
        // Do not decode a field or apply a default before the kind/version gate.
        try SyncRecordFormats.history.validate(kind: rawKind, version: versionNumber.intValue)
        guard versionNumber.intValue == 2,
            let kind = HistoryRecordKind(rawValue: rawKind), record.recordType == kind.recordType,
            let key = HistoryRecordKey(recordName: record.recordID.recordName), key.kind == kind,
            try uuid("entityID", in: record) == key.id,
            let modifiedAt = record["modifiedAt"] as? Date,
            let counter = record["counter"] as? NSNumber, counter.int64Value >= 0,
            counter == NSNumber(value: counter.int64Value),
            let deletion = record["isDeleted"] as? NSNumber,
            deletion == NSNumber(value: 0) || deletion == NSNumber(value: 1)
        else { throw invalid }
        let version = VaultVersion(
            modifiedAt: modifiedAt, counter: counter.uint64Value, writerID: try uuid("writerID", in: record))
        let payload: HistoryRecordPayload?
        if deletion.boolValue {
            payload = nil
        } else {
            switch kind {
            case .connectionHistory:
                guard let rawConnection = record["connectionKind"] as? String,
                    ["ssh", "mosh", "eternalTerminal", "telnet", "sftp"].contains(rawConnection),
                    let connectionKind = ConnectionHistoryEntry.Kind(rawValue: rawConnection),
                    let connectedAt = record["connectedAt"] as? Date
                else { throw invalid }
                let endedAt: Date? = try optional("endedAt", in: record)
                let deviceID: String? = try optional("sourceDeviceID", in: record)
                if let deviceID, UUID(uuidString: deviceID) == nil { throw invalid }
                payload = .connectionHistory(
                    ConnectionHistoryEntry(
                        id: key.id, hostID: try uuid("hostID", in: record),
                        kind: connectionKind, connectedAt: connectedAt,
                        sourceDeviceID: deviceID.flatMap(UUID.init(uuidString:)), endedAt: endedAt))
            case .device:
                guard let name = record["displayName"] as? String else { throw invalid }
                payload = .device(DeviceRecord(id: key.id, displayName: name))
            }
        }
        return HistoryEnvelope(
            key: key, version: version, isDeleted: deletion.boolValue, payload: payload,
            formatVersion: versionNumber.intValue)
    }

    private static func uuid(_ field: String, in record: CKRecord) throws -> UUID {
        guard let raw = record[field] as? String, let value = UUID(uuidString: raw) else {
            throw VaultSyncPersistenceError.invalidEnvelope(record.recordID.recordName)
        }
        return value
    }
    private static func optional<Value>(_ field: String, in record: CKRecord) throws -> Value? {
        guard let raw = record[field] else { return nil }
        guard let value = raw as? Value else {
            throw VaultSyncPersistenceError.invalidEnvelope(record.recordID.recordName)
        }
        return value
    }
}
