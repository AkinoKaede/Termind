import Foundation

nonisolated enum VaultRecordKind: String, Codable, CaseIterable, Sendable {
    case host
    case hostGroup
    case identity
    case sshKey
    case knownHost
    case snippet
    case snippetPackage
    case portForwarding
}

nonisolated struct VaultRecordKey: Codable, Hashable, Sendable {
    var kind: VaultRecordKind
    var id: UUID

    var recordName: String { "v1/\(kind.rawValue)/\(id.uuidString.lowercased())" }

    init(kind: VaultRecordKind, id: UUID) {
        self.kind = kind
        self.id = id
    }

    init?(recordName: String) {
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
nonisolated struct VaultVersion: Codable, Hashable, Sendable, Comparable {
    var modifiedAt: Date
    var counter: UInt64
    var writerID: UUID

    static let baselineDate = Date(timeIntervalSince1970: 0)

    static func baseline(writerID: UUID) -> Self {
        Self(modifiedAt: baselineDate, counter: 0, writerID: writerID)
    }

    static func next(after previous: Self?, writerID: UUID, now: Date = .now) -> Self {
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

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.writerID.uuidString < rhs.writerID.uuidString
    }
}

nonisolated enum VaultRecordPayload: Codable, Hashable, Sendable {
    case host(Host)
    case hostGroup(HostGroup)
    case identity(Identity)
    case sshKey(SSHKeyRef)
    case knownHost(KnownHostEntry)
    case snippet(Snippet)
    case snippetPackage(SnippetPackage)
    case portForwarding(PortForwardingRule)

    var key: VaultRecordKey {
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

nonisolated struct VaultEnvelope: Codable, Hashable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion = Self.currentFormatVersion
    var key: VaultRecordKey
    var version: VaultVersion
    var isDeleted: Bool
    var payload: VaultRecordPayload?

    init(
        key: VaultRecordKey, version: VaultVersion,
        isDeleted: Bool = false, payload: VaultRecordPayload? = nil
    ) {
        self.key = key
        self.version = version
        self.isDeleted = isDeleted
        self.payload = payload
    }

    var isValid: Bool {
        formatVersion == Self.currentFormatVersion
            && (isDeleted ? payload == nil : payload?.key == key)
    }
}

nonisolated struct VaultMutationSet: Equatable, Sendable {
    var keys: Set<VaultRecordKey> = []

    static let empty = Self()
    var isEmpty: Bool { keys.isEmpty }
}

nonisolated enum VaultSyncStatus: Equatable, Sendable {
    case checkingAccount
    case paused
    case unavailable(String)
    case accountChangeConfirmationRequired
    case syncing(pendingCount: Int)
    case upToDate(lastSuccessfulSync: Date?)
    case failed(String)
}
