// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentAIConfigurationSyncEntry {
    @Attribute(.unique) public var recordName = ""
    public var kind = SettingsRecordKind.provider.rawValue
    public var entityID = ""
    public var envelopeData = Data()
    public var systemFieldsData: Data?
    public var needsUpload = false

    public init(envelope: SettingsEnvelope, needsUpload: Bool) throws {
        try apply(envelope, needsUpload: needsUpload)
    }

    public func apply(_ envelope: SettingsEnvelope, needsUpload: Bool) throws {
        recordName = envelope.key.recordName
        kind = envelope.key.kind.rawValue
        entityID = envelope.key.id
        envelopeData = try SettingsSyncCodec.encode(envelope)
        self.needsUpload = needsUpload
    }

    public var envelope: SettingsEnvelope? { try? SettingsSyncCodec.decode(envelopeData) }
}

@Model
public final class PersistentAIConfigurationSyncState {
    @Attribute(.unique) public var key = "ai-configuration-sync"
    public var installationID = UUID()
    public var engineStateData: Data?
    public var boundUserRecordName: String?
    public var pendingUserRecordName: String?
    public var bootstrapCompleted = false
    public var lastSuccessfulSync: Date?

    public init() {}
}

@Model
public final class PersistentAIConfigurationSyncQuarantine {
    @Attribute(.unique) public var recordName = ""
    public var payloadData = Data()
    public var reason = ""
    public var receivedAt = Date()

    public init(recordName: String, payloadData: Data, reason: String) {
        self.recordName = recordName
        self.payloadData = payloadData
        self.reason = reason
    }
}

public nonisolated enum SettingsSyncPersistenceError: LocalizedError {
    case invalidEnvelope(String)
    case unsupportedFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope(let recordName):
            String(localized: "The iCloud settings record \(recordName) is invalid.")
        case .unsupportedFormat(let version):
            String(localized: "This settings record requires sync format \(version).")
        }
    }
}

public nonisolated enum SettingsSyncCodec {
    public static func encode(_ envelope: SettingsEnvelope) throws -> Data {
        guard envelope.isValid else {
            throw SettingsSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    public static func decode(_ data: Data) throws -> SettingsEnvelope {
        try JSONDecoder().decode(SettingsEnvelope.self, from: data)
    }
}
