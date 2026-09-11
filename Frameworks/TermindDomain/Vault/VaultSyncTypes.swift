import Foundation

public nonisolated enum VaultRecordKind: String, Codable, CaseIterable, Sendable {
    case host
    case hostGroup
    case identity
    case sshKey
    case knownHost
    case snippet
    case snippetPackage
    case portForwarding
}

public nonisolated struct VaultRecordKey: Codable, Hashable, Sendable {
    public var kind: VaultRecordKind
    public var id: UUID

    public var recordName: String { "v1/\(kind.rawValue)/\(id.uuidString.lowercased())" }

    public init(kind: VaultRecordKind, id: UUID) {
        self.kind = kind
        self.id = id
    }

    public init?(recordName: String) {
        let components = recordName.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3, components[0] == "v1",
            let kind = VaultRecordKind(rawValue: String(components[1])),
            let id = UUID(uuidString: String(components[2]))
        else { return nil }
        self.init(kind: kind, id: id)
    }
}

/// A hybrid timestamp. `counter` orders multiple writes when wall clocks do not
/// advance, and `writerID` makes ties deterministic across installations.
public nonisolated struct VaultVersion: Codable, Hashable, Sendable, Comparable {
    public var modifiedAt: Date
    public var counter: UInt64
    public var writerID: UUID

    public static let baselineDate = Date(timeIntervalSince1970: 0)

    public static func baseline(writerID: UUID) -> Self {
        Self(modifiedAt: baselineDate, counter: 0, writerID: writerID)
    }

    public static func next(after previous: Self?, writerID: UUID, now: Date = .now) -> Self {
        guard let previous else { return Self(modifiedAt: now, counter: 0, writerID: writerID) }
        if now > previous.modifiedAt {
            return Self(modifiedAt: now, counter: 0, writerID: writerID)
        }
        return Self(
            modifiedAt: previous.modifiedAt,
            counter: previous.counter &+ 1,
            writerID: writerID
        )
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.writerID.uuidString < rhs.writerID.uuidString
    }
    public init(modifiedAt: Date, counter: UInt64, writerID: UUID) {
        self.modifiedAt = modifiedAt
        self.counter = counter
        self.writerID = writerID
    }

}

public nonisolated enum VaultRecordPayload: Codable, Hashable, Sendable {
    case host(Host)
    case hostGroup(HostGroup)
    case identity(Identity)
    case sshKey(SSHKeyRef)
    case knownHost(KnownHostEntry)
    case snippet(Snippet)
    case snippetPackage(SnippetPackage)
    case portForwarding(PortForwardingRule)

    public var key: VaultRecordKey {
        switch self {
        case .host(let value): VaultRecordKey(kind: .host, id: value.id)
        case .hostGroup(let value): VaultRecordKey(kind: .hostGroup, id: value.id)
        case .identity(let value): VaultRecordKey(kind: .identity, id: value.id)
        case .sshKey(let value): VaultRecordKey(kind: .sshKey, id: value.id)
        case .knownHost(let value): VaultRecordKey(kind: .knownHost, id: value.id)
        case .snippet(let value): VaultRecordKey(kind: .snippet, id: value.id)
        case .snippetPackage(let value): VaultRecordKey(kind: .snippetPackage, id: value.id)
        case .portForwarding(let value): VaultRecordKey(kind: .portForwarding, id: value.id)
        }
    }
}

public nonisolated struct VaultEnvelope: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion = Self.currentFormatVersion
    public var key: VaultRecordKey
    public var version: VaultVersion
    public var isDeleted: Bool
    public var payload: VaultRecordPayload?

    public init(
        key: VaultRecordKey, version: VaultVersion,
        isDeleted: Bool = false, payload: VaultRecordPayload? = nil
    ) {
        self.key = key
        self.version = version
        self.isDeleted = isDeleted
        self.payload = payload
    }

    public var isValid: Bool {
        formatVersion == Self.currentFormatVersion
            && (isDeleted ? payload == nil : payload?.key == key)
    }
}

public nonisolated struct VaultMutationSet: Equatable, Sendable {
    public var keys: Set<VaultRecordKey> = []

    public static let empty = Self()
    public var isEmpty: Bool { keys.isEmpty }
    public init(keys: Set<VaultRecordKey> = []) {
        self.keys = keys
    }

}

public nonisolated enum VaultSyncStatus: Equatable, Sendable {
    case checkingAccount
    case paused
    case unavailable(String)
    case accountChangeConfirmationRequired
    case syncing(pendingCount: Int)
    case upToDate(lastSuccessfulSync: Date?)
    case failed(String)
}
