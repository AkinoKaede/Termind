import Foundation

public nonisolated struct SessionPersistenceBackendID: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let tmux = Self(rawValue: "tmux")
}

public nonisolated struct SessionPersistencePreferences: Codable, Hashable, Sendable {
    public enum OnConnect: String, Codable, CaseIterable, Sendable {
        case ask, createManaged, plainShell
    }
    public var enabled: Bool
    public var backend: SessionPersistenceBackendID
    public var onConnect: OnConnect
    public init(enabled: Bool = false, backend: SessionPersistenceBackendID = .tmux, onConnect: OnConnect = .ask) {
        self.enabled = enabled
        self.backend = backend
        self.onConnect = onConnect
    }
}

public nonisolated struct RemoteSessionDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// Versioned backend data, never a command. Only that backend interprets it.
    public let identity: Data
    public let windows: Int?
    public let clients: Int?
    public init(id: String, name: String, identity: Data, windows: Int? = nil, clients: Int? = nil) {
        self.id = id
        self.name = name
        self.identity = identity
        self.windows = windows
        self.clients = clients
    }
}

/// A local recovery reference. URL input must never grant managed ownership.
public nonisolated struct RemoteSessionReference: Codable, Hashable, Sendable {
    public var version: Int = 1
    public var backend: SessionPersistenceBackendID
    public var session: RemoteSessionDescriptor
    public let hostID: UUID
    public let endpoint: String
    public let username: String
    public let ownershipToken: UUID?
    public init(
        backend: SessionPersistenceBackendID, session: RemoteSessionDescriptor,
        hostID: UUID, endpoint: String, username: String, ownershipToken: UUID?
    ) {
        self.backend = backend
        self.session = session
        self.hostID = hostID
        self.endpoint = endpoint
        self.username = username
        self.ownershipToken = ownershipToken
    }
    public var isManaged: Bool { ownershipToken != nil }

    /// Presentation metadata (name and counts) can change without changing the recovery capability.
    public func hasSameIdentity(as other: Self) -> Bool {
        version == other.version && backend == other.backend && hostID == other.hostID
            && endpoint == other.endpoint && username == other.username && ownershipToken == other.ownershipToken
            && session.id == other.session.id && session.identity == other.session.identity
    }
}

public nonisolated enum TerminalTeardownIntent: Sendable {
    case explicitClose, applicationTermination, suspension, remoteExit, detach
    public var endsManagedSession: Bool { self == .explicitClose }
}

public nonisolated enum RemoteSessionFailure: Error, Equatable, Sendable {
    case missing, unsupported, timedOut, invalidResponse, sessionMissing, ownershipMismatch
    case commandFailed(String)
}
