import CryptoKit
import Foundation

/// Public control-plane identity. Neither a login nor a device key belongs here.
public nonisolated struct TailscaleNetwork: Codable, Hashable, Sendable {
    public static let defaultControlURL = "https://controlplane.tailscale.com"
    public var controlURL: String
    public var dnsSuffix: String

    public init(controlURL: String, dnsSuffix: String) throws {
        guard var url = URLComponents(string: controlURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            url.scheme?.lowercased() == "https", let hostname = url.host, !hostname.isEmpty,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { throw TailscaleConfigurationError.invalidControlURL }
        url.scheme = "https"
        url.host = hostname.lowercased()
        if url.port == 443 { url.port = nil }
        while url.path.hasSuffix("/") { url.path.removeLast() }
        if url.host == "login.tailscale.com", url.port == nil, url.path.isEmpty {
            url.host = "controlplane.tailscale.com"
        }
        guard let normalized = url.string else { throw TailscaleConfigurationError.invalidControlURL }
        let suffix = dnsSuffix.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        guard !suffix.isEmpty, !suffix.contains(where: { $0.isWhitespace || $0 == "/" }) else {
            throw TailscaleConfigurationError.missingNetworkIdentity
        }
        self.controlURL = normalized
        self.dnsSuffix = suffix
    }

    private enum CodingKeys: String, CodingKey { case controlURL, dnsSuffix }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            controlURL: container.decode(String.self, forKey: .controlURL),
            dnsSuffix: container.decode(String.self, forKey: .dnsSuffix))
    }

    public var groupID: UUID { Self.identifier(["group", controlURL, dnsSuffix]) }

    public func hostID(stableNodeID: String) -> UUID {
        Self.identifier(["host", controlURL, stableNodeID])
    }

    /// UUIDv5 with the RFC URL namespace and a length-delimited, versioned name.
    /// The algorithm is a storage contract; DNS names and IPs never identify nodes.
    private static func identifier(_ components: [String]) -> UUID {
        let namespace: [UInt8] = [
            0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1,
            0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8,
        ]
        let name = "termind.tailscale.v1:" + components.map { "\($0.utf8.count):\($0)" }.joined()
        var bytes = Array(Insecure.SHA1.hash(data: Data(namespace) + Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}

public nonisolated enum TailscaleConfigurationError: LocalizedError, Sendable {
    case invalidControlURL, missingNetworkIdentity, duplicateNetwork, managedHost, unavailable, requiresPro,
        hostKeyMismatch, loginRequired, peerSSHUnavailable, approvalTimedOut, settingsPending
    public var errorDescription: String? {
        switch self {
        case .settingsPending:
            String(localized: "Tailnet settings are being applied. Try connecting again in a moment.")
        case .loginRequired:
            String(localized: "This device is not connected to the Tailnet. Log in from the group editor.")
        case .peerSSHUnavailable:
            String(localized: "This peer is not advertising Tailscale SSH host keys. Enable Tailscale SSH on the peer.")
        case .approvalTimedOut:
            String(localized: "Tailscale SSH approval timed out. Connect again to request approval.")
        case .invalidControlURL: String(localized: "Enter a valid HTTPS Controlplane URL.")
        case .duplicateNetwork: String(localized: "This Tailnet already belongs to another group.")
        case .requiresPro: String(localized: "Tailscale requires Termind Pro.")
        case .hostKeyMismatch:
            String(localized: "The SSH host key does not match the keys provided by Tailscale.")
        case .managedHost:
            String(localized: "Tailscale manages this host’s address, authentication, and SSH host keys.")
        case .missingNetworkIdentity, .unavailable:
            String(
                localized:
                    "This Tailscale connection is unavailable. Check the Tailnet login, SSH policy, and username.")
        }
    }
}

public nonisolated struct TailscaleHostPreferences: Codable, Hashable, Sendable {
    public var tags: [String] = []
    public var colorTag: TagColor = .none
    public var detectedDistribution: DetectedDistribution?
    public var username = ""
    public var charset: RemoteCharset = .utf8
    public var sftpInitialPath = ""
    public var shellIntegrationMode: HostShellIntegrationMode = .followGlobalSettings
    public var startupSnippetID: UUID?
    public var environmentVariables: [HostEnvironmentVariable] = []
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case tags, colorTag, username, charset, sftpInitialPath, shellIntegrationMode, startupSnippetID,
            environmentVariables, detectedDistribution
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        colorTag = try values.decodeIfPresent(TagColor.self, forKey: .colorTag) ?? .none
        detectedDistribution = try values.decodeIfPresent(DetectedDistribution.self, forKey: .detectedDistribution)
        username = try values.decode(String.self, forKey: .username)
        charset = try values.decode(RemoteCharset.self, forKey: .charset)
        sftpInitialPath = try values.decode(String.self, forKey: .sftpInitialPath)
        shellIntegrationMode = try values.decode(HostShellIntegrationMode.self, forKey: .shellIntegrationMode)
        startupSnippetID = try values.decodeIfPresent(UUID.self, forKey: .startupSnippetID)
        environmentVariables = try values.decode([HostEnvironmentVariable].self, forKey: .environmentVariables)
    }
}

public nonisolated struct TailscaleGroupConfiguration: Codable, Hashable, Sendable {
    public var network: TailscaleNetwork
    public var username = ""
    public var exitNodeID: String?
    public var hostPreferences: [UUID: TailscaleHostPreferences] = [:]
    public init(network: TailscaleNetwork) { self.network = network }
    private enum CodingKeys: String, CodingKey { case network, username, hostPreferences, exitNodeID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        network = try values.decode(TailscaleNetwork.self, forKey: .network)
        exitNodeID = try values.decodeIfPresent(String.self, forKey: .exitNodeID)
        username = try values.decode(String.self, forKey: .username)
        let encoded = try values.decode([String: TailscaleHostPreferences].self, forKey: .hostPreferences)
        for (key, value) in encoded {
            guard let id = UUID(uuidString: key), id.uuidString.lowercased() == key else {
                throw DecodingError.dataCorruptedError(
                    forKey: .hostPreferences, in: values, debugDescription: "Invalid host identifier")
            }
            hostPreferences[id] = value
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(network, forKey: .network)
        try values.encode(username, forKey: .username)
        try values.encodeIfPresent(exitNodeID, forKey: .exitNodeID)
        try values.encode(
            Dictionary(uniqueKeysWithValues: hostPreferences.map { ($0.key.uuidString.lowercased(), $0.value) }),
            forKey: .hostPreferences)
    }
}

/// Device-local discovery, never a Vault Host record.
public nonisolated struct TailscalePeerDetails: Codable, Hashable, Sendable {
    public var addresses: [String]
    public var operatingSystem: String
    public var keyExpiry: Date?
    public var lastSeen: Date?

    public init(addresses: [String], operatingSystem: String, keyExpiry: Date? = nil, lastSeen: Date? = nil) {
        self.addresses = addresses
        self.operatingSystem = operatingSystem
        self.keyExpiry = keyExpiry
        self.lastSeen = lastSeen
    }
}

public nonisolated struct TailscalePeer: Codable, Hashable, Sendable {
    public var stableID: String
    public var name: String
    public var dnsName: String
    public var online: Bool
    public var sshHostKeys: [String]
    public var exitNodeOption: Bool?
    public var details: TailscalePeerDetails?
    public var supportsSSH: Bool { !sshHostKeys.isEmpty }
    public init(
        stableID: String, name: String, dnsName: String, online: Bool, sshHostKeys: [String],
        details: TailscalePeerDetails? = nil, exitNodeOption: Bool? = nil
    ) {
        self.stableID = stableID
        self.name = name
        self.dnsName = dnsName
        self.online = online
        self.sshHostKeys = sshHostKeys
        self.details = details
        self.exitNodeOption = exitNodeOption
    }
}

public nonisolated struct TailscaleHostReference: Codable, Hashable, Sendable {
    public var groupID: UUID
    public var stableNodeID: String
    public init(groupID: UUID, stableNodeID: String) {
        self.groupID = groupID
        self.stableNodeID = stableNodeID
    }
}
