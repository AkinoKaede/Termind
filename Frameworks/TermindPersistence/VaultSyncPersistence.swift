import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentVaultSyncEntry {
    @Attribute(.unique) public var recordName = ""
    public var kind = VaultRecordKind.host.rawValue
    public var entityID = UUID()
    public var envelopeData = Data()
    public var systemFieldsData: Data?
    public var needsUpload = false

    public init(envelope: VaultEnvelope, needsUpload: Bool) throws {
        apply(envelope, needsUpload: needsUpload)
    }

    public func apply(_ envelope: VaultEnvelope, needsUpload: Bool) {
        recordName = envelope.key.recordName
        kind = envelope.key.kind.rawValue
        entityID = envelope.key.id
        envelopeData = VaultSyncCodec.encode(envelope)
        self.needsUpload = needsUpload
    }

    public var envelope: VaultEnvelope? { try? VaultSyncCodec.decode(envelopeData) }
}

@Model
public final class PersistentVaultSyncState {
    @Attribute(.unique) public var key = "vault-sync"
    public var installationID = UUID()
    public var engineStateData: Data?
    public var boundUserRecordName: String?
    public var pendingUserRecordName: String?
    public var bootstrapCompleted = false
    public var lastSuccessfulSync: Date?

    public init() {}
}

@Model
public final class PersistentVaultSyncQuarantine {
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

public nonisolated enum VaultSyncCodec {
    public static func encode(_ envelope: VaultEnvelope) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(envelope)) ?? Data()
    }

    public static func decode(_ data: Data) throws -> VaultEnvelope {
        try JSONDecoder().decode(VaultEnvelope.self, from: data)
    }
}
