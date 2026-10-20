// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

import struct TermindDomain.Host

nonisolated struct HistoryJournalV2: Codable {
    enum Payload: Codable {
        case connectionHistory(HistoryConnectionEntryV2)
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

nonisolated struct HistoryConnectionEntryV2: Codable, Identifiable {
    enum Kind: String, Codable { case ssh, mosh, eternalTerminal, telnet, sftp }
    var id: UUID = UUID()
    var hostID: Host.ID
    var kind: Kind
    var connectedAt: Date = Date()
    var sourceDeviceID: UUID?
    var endedAt: Date?
    init(_ value: TermindDomain.ConnectionHistoryEntry) {
        self.id = value.id
        self.hostID = value.hostID
        self.kind = Kind(rawValue: value.kind.rawValue)!
        self.connectedAt = value.connectedAt
        self.sourceDeviceID = value.sourceDeviceID
        self.endedAt = value.endedAt
    }
    var domainValue: TermindDomain.ConnectionHistoryEntry {
        var result = TermindDomain.ConnectionHistoryEntry(hostID: hostID, kind: .ssh)
        result.id = id
        result.hostID = hostID
        result.kind = TermindDomain.ConnectionHistoryEntry.Kind(rawValue: kind.rawValue)!
        result.connectedAt = connectedAt
        result.sourceDeviceID = sourceDeviceID
        result.endedAt = endedAt
        return result
    }
}
