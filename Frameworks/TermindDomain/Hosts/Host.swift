import Foundation

public nonisolated struct HostEnvironmentVariable: Codable, Hashable, Sendable {
    public var variable: String
    public var value: String

    public init(variable: String, value: String) {
        self.variable = variable
        self.value = value
    }

    public var isValid: Bool {
        guard let first = variable.utf8.first,
            first == Character("_").asciiValue || first.isASCIILetter,
            !variable.contains("\0"), !value.contains("\0")
        else { return false }
        return variable.utf8.dropFirst().allSatisfy {
            $0 == Character("_").asciiValue || $0.isASCIILetter || $0.isASCIIDigit
        }
    }
}
nonisolated

    extension UInt8
{
    fileprivate var isASCIILetter: Bool { (65...90).contains(self) || (97...122).contains(self) }
    fileprivate var isASCIIDigit: Bool { (48...57).contains(self) }
}

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

public nonisolated enum HostTerminalProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case ssh
    case telnet

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .ssh: String(localized: "SSH")
        case .telnet: String(localized: "Telnet")
        }
    }

    public var defaultPort: Int {
        switch self {
        case .ssh: 22
        case .telnet: 23
        }
    }
}

public nonisolated enum HostProtocolRequirement: Hashable, Sendable {
    case anyTerminal
    case ssh
    case telnet
}

/// A saved remote destination with independent SSH and Telnet profiles.
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
    public static let defaultPortForwardingMaxConnections = 1
    public static let portForwardingMaxConnectionsRange = 1...64

    public var id: UUID = UUID()
    public var name: String
    /// Present only on the device-local projection of a discovered Tailscale peer.
    public var tailscale: TailscaleHostReference?
    public var isTailscaleManaged: Bool { tailscale != nil }
    /// Where to connect: an IP literal (v4 or v6) or a DNS name. Named `host`
    /// rather than `hostname` because an IP address is not a hostname, and the
    /// field accepts either.
    public var host: String
    public var sshEnabled = true
    public var sshPort: Int = 22
    /// Which saved login to use. Optional because a host can be filed before it
    /// is known how to get into it; the connection asks at that point.
    public var sshIdentityID: Identity.ID?
    public var sshCharset: RemoteCharset = .utf8
    public var telnetEnabled = false
    public var telnetPort: Int = 23
    public var telnetIdentityID: Identity.ID?
    public var telnetCharset: RemoteCharset = .utf8
    public var telnetProxy: HostProxy?
    /// An optional saved SSH host used to reach this destination. Since the
    /// jump is itself a Host, its own route can form a bounded multi-hop chain.
    public var jumpHostID: Host.ID?
    /// How the current network origin reaches this host. With a jump configured,
    /// the proxy is reached from that jump host rather than directly from Termind.
    public var proxy: HostProxy?
    /// Absolute directory opened by a new SFTP channel. Empty means the
    /// authenticated user's remote home directory, resolved by SFTP at connect.
    public var sftpChannelInitialPath: String = ""
    public var groupID: HostGroup.ID?
    public var tags: [String] = []
    public var colorTag: TagColor = .none
    public var shellIntegrationMode: HostShellIntegrationMode = .followGlobalSettings
    /// Allows the destination to request signatures from this device's Vault keys.
    public var agentForwardingEnabled = false
    /// A reusable script submitted after each interactive SSH shell becomes ready.
    /// The body is resolved from the Snippet library for every connection attempt.
    public var startupSnippetID: Snippet.ID?
    /// Plain-text variables requested on interactive PTY channels before the shell starts.
    /// Servers may reject individual variables according to their AcceptEnv policy.
    public var environmentVariables: [HostEnvironmentVariable] = []
    /// Physical SSH connections available to local and dynamic forwarding on supported platforms.
    public var portForwardingMaxConnections: Int = Self.defaultPortForwardingMaxConnections
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
    public func displayAddress(for connectionProtocol: HostTerminalProtocol) -> String {
        let port = port(for: connectionProtocol)
        var address = host
        if port != connectionProtocol.defaultPort {
            if host.contains(":") { address = "[\(host)]" }
            address += ":\(port)"
        }
        return address
    }

    public func isEnabled(_ connectionProtocol: HostTerminalProtocol) -> Bool {
        switch connectionProtocol {
        case .ssh: sshEnabled
        case .telnet: telnetEnabled
        }
    }

    public func port(for connectionProtocol: HostTerminalProtocol) -> Int {
        switch connectionProtocol {
        case .ssh: sshPort
        case .telnet: telnetPort
        }
    }

    public func identityID(for connectionProtocol: HostTerminalProtocol) -> Identity.ID? {
        switch connectionProtocol {
        case .ssh: sshIdentityID
        case .telnet: telnetIdentityID
        }
    }

    public var supportedTerminalProtocols: [HostTerminalProtocol] {
        HostTerminalProtocol.allCases.filter(isEnabled)
    }

    public var preferredTerminalProtocol: HostTerminalProtocol? {
        if sshEnabled { return .ssh }
        if telnetEnabled { return .telnet }
        return nil
    }

    public func supports(_ requirement: HostProtocolRequirement) -> Bool {
        switch requirement {
        case .anyTerminal: preferredTerminalProtocol != nil
        case .ssh: sshEnabled
        case .telnet: telnetEnabled
        }
    }

    public var port: Int {
        get { sshPort }
        set { sshPort = newValue }
    }

    public var identityID: Identity.ID? {
        get { sshIdentityID }
        set { sshIdentityID = newValue }
    }

    public var charset: RemoteCharset {
        get { sshCharset }
        set { sshCharset = newValue }
    }

    public var displayAddress: String { displayAddress(for: .ssh) }

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
        jumpHostID: Host.ID? = nil, proxy: HostProxy? = nil, sftpChannelInitialPath: String = "",
        charset: RemoteCharset = .utf8,
        sshEnabled: Bool = true, telnetEnabled: Bool = false, telnetPort: Int = 23,
        telnetIdentityID: Identity.ID? = nil, telnetCharset: RemoteCharset = .utf8,
        telnetProxy: HostProxy? = nil,
        groupID: HostGroup.ID? = nil, tags: [String] = [], colorTag: TagColor = .none,
        detectedDistribution: DetectedDistribution? = nil, sortIndex: Double = 0,
        shellIntegrationMode: HostShellIntegrationMode = .followGlobalSettings,
        startupSnippetID: Snippet.ID? = nil, agentForwardingEnabled: Bool = false,
        environmentVariables: [HostEnvironmentVariable] = [],
        portForwardingMaxConnections: Int = Self.defaultPortForwardingMaxConnections
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.sshEnabled = sshEnabled
        sshPort = port
        sshIdentityID = identityID
        sshCharset = charset
        self.telnetEnabled = telnetEnabled
        self.telnetPort = telnetPort
        self.telnetIdentityID = telnetIdentityID
        self.telnetCharset = telnetCharset
        self.telnetProxy = telnetProxy
        self.jumpHostID = jumpHostID
        self.proxy = proxy
        self.sftpChannelInitialPath = sftpChannelInitialPath
        self.groupID = groupID
        self.tags = tags
        self.colorTag = colorTag
        self.detectedDistribution = detectedDistribution
        self.sortIndex = sortIndex
        self.shellIntegrationMode = shellIntegrationMode
        self.startupSnippetID = startupSnippetID
        self.agentForwardingEnabled = agentForwardingEnabled
        self.environmentVariables = environmentVariables
        self.portForwardingMaxConnections = Self.normalizedPortForwardingMaxConnections(
            portForwardingMaxConnections)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, identityID, jumpHostID, proxy, tailscale
        case sftpChannelInitialPath = "sftpSessionInitialPath"
        case charset
        case sshEnabled, telnetEnabled, telnetPort, telnetIdentityID, telnetCharset, telnetProxy
        case groupID, tags, colorTag, detectedDistribution, sortIndex, shellIntegrationMode
        case agentForwardingEnabled, startupSnippetID, environmentVariables, portForwardingMaxConnections
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        tailscale = try values.decodeIfPresent(TailscaleHostReference.self, forKey: .tailscale)
        name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host)
        sshEnabled = try values.decodeIfPresent(Bool.self, forKey: .sshEnabled) ?? true
        sshPort = try values.decode(Int.self, forKey: .port)
        sshIdentityID = try values.decodeIfPresent(UUID.self, forKey: .identityID)
        telnetEnabled = try values.decodeIfPresent(Bool.self, forKey: .telnetEnabled) ?? false
        telnetPort = try values.decodeIfPresent(Int.self, forKey: .telnetPort) ?? 23
        telnetIdentityID = try values.decodeIfPresent(UUID.self, forKey: .telnetIdentityID)
        telnetProxy = try values.decodeIfPresent(HostProxy.self, forKey: .telnetProxy)
        telnetCharset =
            try values.decodeIfPresent(String.self, forKey: .telnetCharset)
            .flatMap(RemoteCharset.init(rawValue:)) ?? .utf8
        jumpHostID = try values.decodeIfPresent(UUID.self, forKey: .jumpHostID)
        proxy = try values.decodeIfPresent(HostProxy.self, forKey: .proxy)
        sftpChannelInitialPath = try values.decode(String.self, forKey: .sftpChannelInitialPath)
        sshCharset =
            try values.decodeIfPresent(String.self, forKey: .charset)
            .flatMap(RemoteCharset.init(rawValue:)) ?? .utf8
        groupID = try values.decodeIfPresent(UUID.self, forKey: .groupID)
        tags = try values.decode([String].self, forKey: .tags)
        colorTag = try values.decode(TagColor.self, forKey: .colorTag)
        detectedDistribution = try values.decodeIfPresent(DetectedDistribution.self, forKey: .detectedDistribution)
        sortIndex = try values.decode(Double.self, forKey: .sortIndex)
        shellIntegrationMode =
            try values.decodeIfPresent(String.self, forKey: .shellIntegrationMode)
            .flatMap(HostShellIntegrationMode.init(rawValue:)) ?? .followGlobalSettings
        agentForwardingEnabled = try values.decodeIfPresent(Bool.self, forKey: .agentForwardingEnabled) ?? false
        startupSnippetID = try values.decodeIfPresent(Snippet.ID.self, forKey: .startupSnippetID)
        environmentVariables =
            try values.decodeIfPresent([HostEnvironmentVariable].self, forKey: .environmentVariables) ?? []
        portForwardingMaxConnections = Self.normalizedPortForwardingMaxConnections(
            try values.decodeIfPresent(Int.self, forKey: .portForwardingMaxConnections)
                ?? Self.defaultPortForwardingMaxConnections)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(tailscale, forKey: .tailscale)
        try values.encode(name, forKey: .name)
        try values.encode(host, forKey: .host)
        try values.encode(sshPort, forKey: .port)
        try values.encodeIfPresent(sshIdentityID, forKey: .identityID)
        try values.encodeIfPresent(jumpHostID, forKey: .jumpHostID)
        try values.encodeIfPresent(proxy, forKey: .proxy)
        try values.encode(sftpChannelInitialPath, forKey: .sftpChannelInitialPath)
        try values.encode(sshCharset.rawValue, forKey: .charset)
        try values.encode(sshEnabled, forKey: .sshEnabled)
        try values.encode(telnetEnabled, forKey: .telnetEnabled)
        try values.encode(telnetPort, forKey: .telnetPort)
        try values.encodeIfPresent(telnetIdentityID, forKey: .telnetIdentityID)
        try values.encode(telnetCharset.rawValue, forKey: .telnetCharset)
        try values.encodeIfPresent(telnetProxy, forKey: .telnetProxy)
        try values.encodeIfPresent(groupID, forKey: .groupID)
        try values.encode(tags, forKey: .tags)
        try values.encode(colorTag, forKey: .colorTag)
        try values.encodeIfPresent(detectedDistribution, forKey: .detectedDistribution)
        try values.encode(sortIndex, forKey: .sortIndex)
        try values.encode(shellIntegrationMode.rawValue, forKey: .shellIntegrationMode)
        try values.encode(agentForwardingEnabled, forKey: .agentForwardingEnabled)
        try values.encodeIfPresent(startupSnippetID, forKey: .startupSnippetID)
        try values.encode(environmentVariables, forKey: .environmentVariables)
        try values.encode(portForwardingMaxConnections, forKey: .portForwardingMaxConnections)
    }

    public static func normalizedPortForwardingMaxConnections(_ value: Int) -> Int {
        min(max(value, portForwardingMaxConnectionsRange.lowerBound), portForwardingMaxConnectionsRange.upperBound)
    }

    public var environmentVariablesAreValid: Bool {
        environmentVariables.allSatisfy(\.isValid)
            && Set(environmentVariables.map(\.variable)).count == environmentVariables.count
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
    public var tailscale: TailscaleGroupConfiguration?
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
