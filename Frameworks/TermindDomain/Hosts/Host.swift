import Foundation

public nonisolated struct HostProxy: Codable, Hashable, Sendable {
    public nonisolated enum ProtocolKind: String, Codable, CaseIterable, Identifiable, Sendable {
        case http
        case socks5

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .http: String(localized: "HTTP")
            case .socks5: String(localized: "SOCKS5")
            }
        }

        public var defaultPort: Int {
            switch self {
            case .http: 8080
            case .socks5: 1080
            }
        }
    }

    public var kind: ProtocolKind = .http
    public var hostname: String = ""
    public var port: Int = 8080
    /// The proxy login may intentionally differ from the Identity's SSH login.
    /// The selected Identity supplies only the password from Keychain.
    public var username: String = ""
    public var identityID: Identity.ID?

    public var isValid: Bool {
        !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65_535).contains(port)
            && (identityID == nil
                ? username.trimmingCharacters(in: .whitespaces).isEmpty
                : !username.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    public init(
        kind: ProtocolKind = .http, hostname: String = "", port: Int = 8080, username: String = "",
        identityID: Identity.ID? = nil
    ) {
        self.kind = kind
        self.hostname = hostname
        self.port = port
        self.username = username
        self.identityID = identityID
    }

}

/// A saved SSH destination.
///
/// This is a plain value type, not a SwiftData `@Model`. P1 swaps `HostLibraryModel`'s
/// internals for a `ModelContext` and keeps this struct as the projection the
/// views bind to. That indirection is worth it twice over: CloudKit forces every
/// `@Model` property to be optional-or-defaulted, which makes `@Model` classes
/// awkward to bind directly, and the SSH layer at P2 needs to read a host from
/// outside the main actor.
///
/// A host says *where* to connect and nothing about *who* connects — the login
/// name and the secret both belong to `Identity`, which is shared across a fleet.
/// So there is no `username` and no `credentialRef` here, only `identityID`, and
/// therefore no path by which a secret could reach SwiftData or CloudKit.
public nonisolated struct Host: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    /// Where to connect: an IP literal (v4 or v6) or a DNS name. Named `host`
    /// rather than `hostname` because an IP address is not a hostname, and the
    /// field accepts either.
    public var host: String
    public var port: Int = 22
    /// Which saved login to use. Optional because a host can be filed before it
    /// is known how to get into it; the connection asks at that point.
    public var identityID: Identity.ID?
    /// An optional saved SSH host used to reach this destination. Since the
    /// jump is itself a Host, its own route can form a bounded multi-hop chain.
    public var jumpHostID: Host.ID?
    /// How the current network origin reaches this host. With a jump configured,
    /// the proxy is reached from that jump host rather than directly from Termind.
    public var proxy: HostProxy?
    /// Absolute directory opened by a new SFTP session. Empty means the
    /// authenticated user's remote home directory, resolved by SFTP at connect.
    public var sftpSessionInitialPath: String = ""
    public var groupID: HostGroup.ID?
    public var tags: [String] = []
    public var colorTag: TagColor = .none
    /// Last distribution reported by Shell Integration for this saved Host.
    /// System-owned: editor saves preserve it and only a validated probe updates it.
    public var detectedDistribution: DetectedDistribution?
    /// Fractional index so reordering never has to renumber siblings — CloudKit
    /// has no ordered relationships, so order has to be an ordinary attribute.
    public var sortIndex: Double = 0

    /// The address alone, with `:port` appended when it is not the default.
    ///
    /// An IPv6 literal is bracketed once a port follows it — `::1:2222` is
    /// ambiguous, since the trailing group could be part of the address. With no
    /// port there is nothing to disambiguate, so the bare form is kept: that is
    /// what the user typed and what OpenSSH itself writes.
    ///
    /// The `user@` half needs the identity, which lives in the store — see
    /// `HostLibraryModel.loginAddress(for:)` for the form most of the UI shows.
    public var displayAddress: String {
        var address = host
        if port != 22 {
            if host.contains(":") { address = "[\(host)]" }
            address += ":\(port)"
        }
        return address
    }

    /// Whether this host carries *every* one of `wanted`.
    ///
    /// Narrowing rather than widening: picking `nginx` and `prod` in the Hosts
    /// page filter asks for the machines that are both, which is the reading
    /// that makes a second tag useful. An empty set matches everything, so the
    /// caller can apply it unconditionally.
    public func hasTags(_ wanted: Set<String>) -> Bool {
        guard !wanted.isEmpty else { return true }
        let mine = Set(tags.map { $0.lowercased() })
        return wanted.allSatisfy { mine.contains($0.lowercased()) }
    }

    /// Matches the search field against everything this value knows. The login
    /// name is *not* here because it is not here — `HostLibraryModel.searchHosts`
    /// resolves the identity and matches that too.
    public func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return name.lowercased().contains(q)
            || host.lowercased().contains(q)
            || tags.contains { $0.lowercased().contains(q) }
    }
    public init(
        id: UUID = UUID(), name: String, host: String, port: Int = 22, identityID: Identity.ID? = nil,
        jumpHostID: Host.ID? = nil, proxy: HostProxy? = nil, sftpSessionInitialPath: String = "",
        groupID: HostGroup.ID? = nil, tags: [String] = [], colorTag: TagColor = .none,
        detectedDistribution: DetectedDistribution? = nil, sortIndex: Double = 0
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.identityID = identityID
        self.jumpHostID = jumpHostID
        self.proxy = proxy
        self.sftpSessionInitialPath = sftpSessionInitialPath
        self.groupID = groupID
        self.tags = tags
        self.colorTag = colorTag
        self.detectedDistribution = detectedDistribution
        self.sortIndex = sortIndex
    }

}

/// A user-defined folder of hosts. `parentID` is optional and self-referential,
/// which is also what CloudKit requires of the eventual relationship.
public nonisolated struct HostGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var parentID: HostGroup.ID?
    public var sortIndex: Double = 0
    public var isExpanded: Bool = true
    public init(
        id: UUID = UUID(), name: String, parentID: HostGroup.ID? = nil, sortIndex: Double = 0, isExpanded: Bool = true
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.sortIndex = sortIndex
        self.isExpanded = isExpanded
    }

}

public nonisolated enum ConnectionStatus: Hashable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .connecting, .reconnecting: true
        default: false
        }
    }

    public var isLive: Bool { self == .connected }
}
