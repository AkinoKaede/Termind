import Foundation

public nonisolated struct SyncedMetricsSelection: Codable, Hashable, Sendable {
    public var selection: MetricsSelection
    public var sortIndex: Int

    public init(selection: MetricsSelection, sortIndex: Int) {
        self.selection = selection
        self.sortIndex = sortIndex
    }
}

public nonisolated enum MetricsRecordKind: String, Codable, CaseIterable, Sendable {
    case selection
}

public nonisolated struct MetricsRecordKey: Codable, Hashable, Sendable {
    public var kind: MetricsRecordKind
    public var id: UUID
    public var recordName: String { "v1/\(kind.rawValue)/\(id.uuidString.lowercased())" }

    public init(kind: MetricsRecordKind = .selection, id: UUID) {
        self.kind = kind
        self.id = id
    }

    public init?(recordName: String) {
        let parts = recordName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v1",
            let kind = MetricsRecordKind(rawValue: String(parts[1])),
            let id = UUID(uuidString: String(parts[2])),
            id.uuidString.lowercased() == parts[2]
        else { return nil }
        self.init(kind: kind, id: id)
    }
}

public nonisolated enum MetricsRecordPayload: Codable, Hashable, Sendable {
    case selection(SyncedMetricsSelection)

    public var key: MetricsRecordKey {
        switch self {
        case .selection(let value): MetricsRecordKey(id: value.selection.id)
        }
    }
}

public nonisolated struct MetricsEnvelope: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1
    public var formatVersion = Self.currentFormatVersion
    public var key: MetricsRecordKey
    public var version: VaultVersion
    public var isDeleted = false
    public var payload: MetricsRecordPayload?

    public init(
        formatVersion: Int = MetricsEnvelope.currentFormatVersion,
        key: MetricsRecordKey, version: VaultVersion, isDeleted: Bool = false,
        payload: MetricsRecordPayload? = nil
    ) {
        self.formatVersion = formatVersion
        self.key = key
        self.version = version
        self.isDeleted = isDeleted
        self.payload = payload
    }

    public var isValid: Bool {
        formatVersion == Self.currentFormatVersion
            && MetricsRecordKey(recordName: key.recordName) == key
            && (isDeleted ? payload == nil : payload?.key == key)
    }
}

public nonisolated struct MetricsSyncSnapshot: Equatable, Sendable {
    public var selections: [MetricsSelection]

    public init(selections: [MetricsSelection] = []) { self.selections = selections }

    public var recordPayloads: [MetricsRecordKey: MetricsRecordPayload] {
        Dictionary(
            uniqueKeysWithValues: selections.enumerated().map { index, selection in
                let payload = MetricsRecordPayload.selection(
                    SyncedMetricsSelection(selection: selection, sortIndex: index))
                return (payload.key, payload)
            })
    }
}

public nonisolated struct MetricsMutationSet: Equatable, Sendable {
    public var keys: Set<MetricsRecordKey> = []
    public static let empty = Self()
    public var isEmpty: Bool { keys.isEmpty }
    public init(keys: Set<MetricsRecordKey> = []) { self.keys = keys }
}
