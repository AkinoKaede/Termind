import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentMetricsSyncEntry {
    @Attribute(.unique) public var recordName = ""
    public var kind = MetricsRecordKind.selection.rawValue
    public var entityID = ""
    public var envelopeData = Data()
    public var systemFieldsData: Data?
    public var needsUpload = false

    public init(envelope: MetricsEnvelope, needsUpload: Bool) throws {
        try apply(envelope, needsUpload: needsUpload)
    }

    public func apply(_ envelope: MetricsEnvelope, needsUpload: Bool) throws {
        recordName = envelope.key.recordName
        kind = envelope.key.kind.rawValue
        entityID = envelope.key.id.uuidString.lowercased()
        envelopeData = try MetricsSyncCodec.encode(envelope)
        self.needsUpload = needsUpload
    }

    public var envelope: MetricsEnvelope? { try? MetricsSyncCodec.decode(envelopeData) }
}

@Model
public final class PersistentMetricsSyncState {
    @Attribute(.unique) public var key = "metrics-sync"
    public var installationID = UUID()
    public var engineStateData: Data?
    public var boundUserRecordName: String?
    public var pendingUserRecordName: String?
    public var bootstrapCompleted = false
    public var lastSuccessfulSync: Date?

    public init() {}
}

@Model
public final class PersistentMetricsSyncQuarantine {
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

public nonisolated enum MetricsSyncPersistenceError: LocalizedError {
    case invalidEnvelope(String)
    case unsupportedFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope(let recordName):
            String(localized: "The iCloud Metrics record \(recordName) is invalid.")
        case .unsupportedFormat(let version):
            String(localized: "This Metrics record requires sync format \(version).")
        }
    }
}

public nonisolated enum MetricsSyncCodec {
    public static func encode(_ envelope: MetricsEnvelope) throws -> Data {
        guard envelope.isValid else {
            throw MetricsSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    public static func decode(_ data: Data) throws -> MetricsEnvelope {
        try JSONDecoder().decode(MetricsEnvelope.self, from: data)
    }
}
