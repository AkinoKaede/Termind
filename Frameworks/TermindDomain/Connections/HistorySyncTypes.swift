import Foundation

public nonisolated enum HistoryRecordKind: String, Codable, CaseIterable, Sendable {
    case connectionHistory
    case device

    public var recordType: String {
        switch self {
        case .connectionHistory: "ConnectionHistoryItem"
        case .device: "DeviceItem"
        }
    }
}

/// The name's v1 prefix is a stable identity namespace, not the payload version.
/// Moving the identity to another zone preserves the UUID but never its CK system fields.
public nonisolated struct HistoryRecordKey: Codable, Hashable, Sendable {
    public var kind: HistoryRecordKind
    public var id: UUID
    public var recordName: String { "v1/\(kind.rawValue)/\(id.uuidString.lowercased())" }
    public init(kind: HistoryRecordKind, id: UUID) {
        self.kind = kind
        self.id = id
    }
    public init?(recordName: String) {
        let parts = recordName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v1",
            let kind = HistoryRecordKind(rawValue: String(parts[1])), let id = UUID(uuidString: String(parts[2]))
        else { return nil }
        self.init(kind: kind, id: id)
    }
}

public nonisolated enum HistoryRecordPayload: Codable, Hashable, Sendable {
    case connectionHistory(ConnectionHistoryEntry)
    case device(DeviceRecord)
    public var key: HistoryRecordKey {
        switch self {
        case .connectionHistory(let value): .init(kind: .connectionHistory, id: value.id)
        case .device(let value): .init(kind: .device, id: value.id)
        }
    }
}

public nonisolated struct HistoryEnvelope: Codable, Hashable, Sendable {
    public var formatVersion: Int
    public var key: HistoryRecordKey
    public var version: VaultVersion
    public var isDeleted: Bool
    public var payload: HistoryRecordPayload?
    public init(
        key: HistoryRecordKey, version: VaultVersion, isDeleted: Bool = false,
        payload: HistoryRecordPayload? = nil, formatVersion: Int? = nil
    ) {
        self.key = key
        self.version = version
        self.isDeleted = isDeleted
        self.payload = payload
        self.formatVersion = formatVersion ?? SyncRecordFormats.history.writingVersion(for: key.kind.rawValue)
    }
    public var isValid: Bool {
        guard SyncRecordFormats.history.supports(kind: key.kind.rawValue, version: formatVersion) else { return false }
        return isDeleted ? payload == nil : payload?.key == key
    }

    /// Adapts only the legacy history kinds. It must not invent a newer modification
    /// timestamp: every device importing the same legacy write must converge.
    public init?(legacy: VaultEnvelope) {
        guard let kind = HistoryRecordKind(rawValue: legacy.key.kind.rawValue) else { return nil }
        let payload: HistoryRecordPayload?
        switch legacy.payload {
        case .connectionHistory(let value): payload = .connectionHistory(value)
        case .device(let value): payload = .device(value)
        case nil: payload = nil
        default: return nil
        }
        self.init(
            key: .init(kind: kind, id: legacy.key.id), version: legacy.version,
            isDeleted: legacy.isDeleted, payload: payload, formatVersion: legacy.formatVersion)
    }
}

public nonisolated struct HistoryMutationSet: Equatable, Sendable {
    public var keys: Set<HistoryRecordKey>
    public static let empty = Self()
    public var isEmpty: Bool { keys.isEmpty }
    public init(keys: Set<HistoryRecordKey> = []) { self.keys = keys }
}

nonisolated extension HistoryEnvelope {
    /// V1 history uses the shipped payload shape. This is a wire adapter only;
    /// it never grants permission to save the resulting envelope in the Vault zone.
    public var legacyEnvelope: VaultEnvelope {
        let value: VaultRecordPayload?
        switch payload {
        case .connectionHistory(let entry): value = .connectionHistory(entry)
        case .device(let device): value = .device(device)
        case nil: value = nil
        }
        return VaultEnvelope(
            key: .init(kind: key.kind == .device ? .device : .connectionHistory, id: key.id),
            version: version, isDeleted: isDeleted, payload: value, formatVersion: formatVersion)
    }
}
