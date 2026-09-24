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

    public init(recordName: String, data: Data) {
        self.recordName = recordName
        envelopeData = data
        needsUpload = true
    }
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

/// Importer state is replica-scoped and separate from both configuration and History
/// engines. It never stores upload intent, including restored queues from older code.
@Model
public final class PersistentHistoryImportState {
    @Attribute(.unique) public var scopeKey = ""
    public var engineStateData: Data?
    public var requiresRefetch = true
    public var capabilityID = ""
    public init(scopeKey: String) { self.scopeKey = scopeKey }
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
        return try encoder.encode(VaultWireV1.Envelope(envelope.legacyEnvelope))
    }
    private static let decoder = VersionedRecordDecoder<HistoryEnvelope>(
        Dictionary(
            uniqueKeysWithValues: HistoryRecordKind.allCases.map { kind in
                (
                    kind.rawValue,
                    [
                        1: { data in
                            let legacy = try JSONDecoder().decode(VaultWireV1.Envelope.self, from: data).domainValue
                            guard let value = HistoryEnvelope(legacy: legacy), value.isValid else {
                                throw VaultSyncPersistenceError.invalidEnvelope(legacy.key.recordName)
                            }
                            return value
                        }
                    ]
                )
            }))
    public static func decode(_ data: Data) throws -> HistoryEnvelope { try decoder.decode(data) }
}
