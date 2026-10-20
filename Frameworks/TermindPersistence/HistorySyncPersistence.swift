// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData
import TermindDomain

/// V35 additions. Existing models stay frozen so TestFlight stores can migrate.
@Model
public final class PersistentHistorySyncEntry {
    @Attribute(.unique) public var recordName = ""
    public var envelopeData = Data()
    public var systemFieldsData: Data?
    public var needsUpload = false

    public init(envelope: HistoryEnvelope, needsUpload: Bool) throws {
        try apply(envelope, needsUpload: needsUpload)
    }
    public func apply(_ envelope: HistoryEnvelope, needsUpload: Bool) throws {
        let data = try HistorySyncCodec.encode(envelope)
        recordName = envelope.key.recordName
        envelopeData = data
        self.needsUpload = needsUpload
    }
    public var envelope: HistoryEnvelope? { try? HistorySyncCodec.decode(envelopeData) }
}

@Model
public final class PersistentHistorySyncState {
    @Attribute(.unique) public var key = "history-sync"
    public var installationID = UUID()
    public var engineStateData: Data?
    public var boundUserRecordName: String?
    public var pendingUserRecordName: String?
    public var bootstrapCompleted = false
    public var lastSuccessfulSync: Date?
    public init() {}
}

@Model
public final class PersistentSyncCapability {
    @Attribute(.unique) public var scopeKey = ""
    public var capabilityID = ""
    public init(scopeKey: String) { self.scopeKey = scopeKey }
}

public nonisolated enum HistorySyncCodec {
    public static func encode(_ envelope: HistoryEnvelope) throws -> Data {
        try SyncRecordFormats.history.validate(kind: envelope.key.kind.rawValue, version: envelope.formatVersion)
        guard envelope.isValid else { throw VaultSyncPersistenceError.invalidEnvelope(envelope.key.recordName) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if envelope.formatVersion == 2 { return try encoder.encode(HistoryJournalV2(envelope)) }
        if case .connectionHistory(let value) = envelope.payload, value.kind.terminalProtocol?.isResumable == true {
            throw CocoaError(.coderInvalidValue)
        }
        return try encoder.encode(HistoryJournalV1(envelope))
    }
    private static let decoder: VersionedRecordDecoder<HistoryEnvelope> = {
        var decoders: [String: [Int: @Sendable (Data) throws -> HistoryEnvelope]] = [:]
        for kind in HistoryRecordKind.allCases {
            decoders[kind.rawValue] = [1: { try JSONDecoder().decode(HistoryJournalV1.self, from: $0).domainValue }]
        }
        decoders[HistoryRecordKind.connectionHistory.rawValue]?[2] = {
            try JSONDecoder().decode(HistoryJournalV2.self, from: $0).domainValue
        }
        return VersionedRecordDecoder(decoders)
    }()
    public static func decode(_ data: Data) throws -> HistoryEnvelope {
        let value = try decoder.decode(data)
        guard value.isValid else { throw VaultSyncPersistenceError.invalidEnvelope(value.key.recordName) }
        return value
    }
}

/// Frozen local journal shape. Reuse the shipped value DTOs without adapting through a Vault envelope.
private nonisolated struct HistoryJournalV1: Codable {
    enum Payload: Codable {
        case connectionHistory(VaultWireV1.ConnectionHistoryEntry)
        case device(VaultWireV1.DeviceRecord)

        init(_ value: HistoryRecordPayload) {
            switch value {
            case .connectionHistory(let value): self = .connectionHistory(.init(value))
            case .device(let value): self = .device(.init(value))
            }
        }

        var domainValue: HistoryRecordPayload {
            switch self {
            case .connectionHistory(let value): .connectionHistory(value.domainValue)
            case .device(let value): .device(value.domainValue)
            }
        }
    }

    var formatVersion: Int
    var key: HistoryRecordKey
    var version: VaultVersion
    var isDeleted: Bool
    var payload: Payload?

    init(_ value: HistoryEnvelope) {
        formatVersion = value.formatVersion
        key = value.key
        version = value.version
        isDeleted = value.isDeleted
        payload = value.payload.map(Payload.init)
    }

    var domainValue: HistoryEnvelope {
        HistoryEnvelope(
            key: key, version: version, isDeleted: isDeleted,
            payload: payload?.domainValue, formatVersion: formatVersion)
    }
}
