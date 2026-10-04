import CryptoKit
import Foundation
import TailscaleKit
import TermindApplication
import TermindDomain

/// Owns one embedded userspace node; no system VPN or daemon is required.
public actor LibTailscaleNodeSession: TailscaleNodeSession {
    public nonisolated static var version: String { Node.version }

    private let node: Node
    private let controlURL: String

    private init(node: Node, controlURL: String) {
        self.node = node
        self.controlURL = controlURL
    }

    public static let factory: TailscaleNodeFactory = { profileID, hostname, controlURL, authKey in
        try await Task.detached {
            let directory = try profileDirectory(profileID)
            let node = try Node(
                hostname: hostname, directory: directory, controlURL: controlURL,
                stateNamespace: stateNamespace(profileID), authKey: authKey
            )
            return LibTailscaleNodeSession(node: node, controlURL: controlURL)
        }.value
    }

    public static let profileStorage = TailscaleProfileStorage(
        profiles: {
            try await Task.detached { try storedProfiles(in: profileRoot()) }.value
        },
        erase: { id in
            try await Task.detached {
                try Node.eraseState(directory: profileDirectory(id), stateNamespace: stateNamespace(id))
            }.value
        })

    private nonisolated static func stateNamespace(_ id: UUID) -> String {
        "com.akinokaede.termind.tailscale.\(id.uuidString)"
    }

    private nonisolated static func profileRoot() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("Termind/Tailscale", isDirectory: true)
    }

    private nonisolated static func profileDirectory(_ id: UUID) throws -> URL {
        try profileRoot().appendingPathComponent(id.uuidString, isDirectory: true)
    }

    nonisolated static func storedProfiles(in root: URL) throws -> Set<UUID> {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch CocoaError.fileReadNoSuchFile { return [] }
        return try Set(
            entries.compactMap { url in
                guard let id = UUID(uuidString: url.lastPathComponent), id.uuidString == url.lastPathComponent else {
                    return nil
                }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true && values.isSymbolicLink != true ? id : nil
            })
    }

    public func status() async throws -> TailscaleNodeStatus {
        let data = try await node.request(path: "status")
        return try Self.decodeStatus(data, controlURL: controlURL)
    }

    public static func decodeStatus(_ data: Data, controlURL: String) throws -> TailscaleNodeStatus {
        let status = try JSONDecoder().decode(Status.self, from: data)
        let network = try status.currentTailnet.map {
            try TailscaleNetwork(controlURL: controlURL, dnsSuffix: $0.magicDNSSuffix)
        }
        // A missing peer map is not an authoritative empty snapshot.
        let running = status.backendState == "Running" && network != nil
        let peers = (status.peers ?? [:]).values.filter {
            $0.inNetworkMap && $0.shareeNode != true && !$0.stableID.isEmpty && !$0.dnsName.isEmpty
        }.map {
            TailscalePeer(
                stableID: $0.stableID, name: $0.hostName,
                dnsName: $0.dnsName.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                online: $0.online, sshHostKeys: $0.sshHostKeys ?? [],
                details: TailscalePeerDetails(
                    addresses: $0.tailscaleIPs ?? [], operatingSystem: $0.os ?? "",
                    keyExpiry: Self.date($0.keyExpiry), lastSeen: Self.date($0.lastSeen)),
                exitNodeOption: $0.exitNodeOption)
        }.sorted { $0.stableID < $1.stableID }
        let device = try status.localDevice.map { local in
            let expiry: Date?
            if let raw = local.keyExpiry, !raw.hasPrefix("0001-") {
                expiry =
                    try (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw))
                    ?? Date.ISO8601FormatStyle().parse(raw)
            } else {
                expiry = nil
            }
            return TailscaleDeviceInfo(
                networkName: status.currentTailnet?.name ?? network?.dnsSuffix ?? "",
                dnsName: (local.dnsName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                hostname: local.hostName ?? "", addresses: local.tailscaleIPs ?? [], operatingSystem: local.os ?? "",
                keyExpiry: expiry)
        }
        return TailscaleNodeStatus(
            running: running, network: network,
            authURL: status.authURL.flatMap(URL.init(string:)), peers: peers, device: device
        )
    }

    private static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.hasPrefix("0001-") else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw))
            ?? (try? Date.ISO8601FormatStyle().parse(raw))
    }

    public func setHostname(_ hostname: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["Hostname": hostname, "HostnameSet": true])
        _ = try await node.request(method: "PATCH", path: "prefs", body: String(decoding: body, as: UTF8.self))
    }

    public func setExitNode(_ stableID: String?) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "ExitNodeID": stableID ?? "", "ExitNodeIDSet": true,
            "ExitNodeIP": "", "ExitNodeIPSet": true, "AutoExitNode": "", "AutoExitNodeSet": true,
        ])
        _ = try await node.request(method: "PATCH", path: "prefs", body: String(decoding: body, as: UTF8.self))
    }

    public func ping(ip: String) async throws -> TailscalePingResult {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "ip", value: ip), URLQueryItem(name: "type", value: "disco")]
        let data = try await node.request(method: "POST", path: "ping?" + (query.percentEncodedQuery ?? ""))
        return try Self.decodePing(data)
    }

    public static func decodePing(_ data: Data) throws -> TailscalePingResult {
        struct Response: Decodable {
            var error: String?
            var latencySeconds: Double?
            var endpoint: String?
            var peerRelay: String?
            var derpRegionID: Int?
            var derpRegionCode: String?
            enum CodingKeys: String, CodingKey {
                case error = "Err"
                case latencySeconds = "LatencySeconds"
                case endpoint = "Endpoint"
                case peerRelay = "PeerRelay"
                case derpRegionID = "DERPRegionID"
                case derpRegionCode = "DERPRegionCode"
            }
        }
        let value = try JSONDecoder().decode(Response.self, from: data)
        if let error = value.error, !error.isEmpty { throw TermindSSHError.library(error) }
        guard let latency = value.latencySeconds, latency.isFinite, latency >= 0 else {
            throw TailscaleConfigurationError.unavailable
        }
        let route: TailscalePingResult.Route
        if let endpoint = value.endpoint, !endpoint.isEmpty {
            route = .direct(endpoint)
        } else if let relay = value.peerRelay, !relay.isEmpty {
            route = .peerRelay(relay)
        } else if let id = value.derpRegionID, id != 0 {
            route = .derp(value.derpRegionCode ?? String(id))
        } else {
            route = .unknown
        }
        return TailscalePingResult(milliseconds: latency * 1000, route: route)
    }

    public func login() async throws { _ = try await node.request(method: "POST", path: "login-interactive") }
    public func logout() async throws {
        _ = try? await node.request(method: "POST", path: "logout")
        await node.close()
        // The model's durable profile cleanup queue owns local erasure and retry.
    }
    public func close() async { await node.close() }
    public func dial(host: String, port: Int, timeout: TimeInterval) async throws -> Int32 {
        try await node.dial(host: host, port: port, timeout: Int32(max(1, min(timeout, 600))))
    }

    public func hostKeys(stableNodeID: String) async throws -> Set<SSHHostKeyIdentity> {
        let status = try await status()
        guard status.running else { throw TailscaleConfigurationError.loginRequired }
        guard let peer = status.peers.first(where: { $0.stableID == stableNodeID }) else {
            throw TailscaleConfigurationError.peerSSHUnavailable
        }
        let keys = Set(peer.sshHostKeys.compactMap(Self.hostKey))
        guard !keys.isEmpty else { throw TailscaleConfigurationError.peerSSHUnavailable }
        return keys
    }

    public static func hostKey(_ line: String) -> SSHHostKeyIdentity? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, let algorithm = SSHKeyAlgorithm(rawValue: String(fields[0])),
            let blob = Data(base64Encoded: String(fields[1])), blob.count > 4
        else { return nil }
        let length = blob.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= blob.count - 4,
            String(data: blob.subdata(in: 4..<(4 + length)), encoding: .utf8) == algorithm.rawValue
        else { return nil }
        let fingerprint = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return SSHHostKeyIdentity(algorithm: algorithm, fingerprint: "SHA256:\(fingerprint)")
    }

    private struct Status: Decodable {
        var backendState: String
        var authURL: String?
        var currentTailnet: Tailnet?
        var peers: [String: PeerStatus]?
        var localDevice: LocalDevice?
        enum CodingKeys: String, CodingKey {
            case backendState = "BackendState"
            case authURL = "AuthURL"
            case currentTailnet = "CurrentTailnet"
            case peers = "Peer"
            case localDevice = "Self"
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            backendState = try values.decode(String.self, forKey: .backendState)
            authURL = try values.decodeIfPresent(String.self, forKey: .authURL)
            currentTailnet = try values.decodeIfPresent(Tailnet.self, forKey: .currentTailnet)
            // Null is the upstream representation of a successful empty list.
            peers = try values.decode([String: PeerStatus]?.self, forKey: .peers)
            localDevice = try values.decodeIfPresent(LocalDevice.self, forKey: .localDevice)
        }
        struct Tailnet: Decodable {
            var name: String?
            var magicDNSSuffix: String
            enum CodingKeys: String, CodingKey {
                case name = "Name"
                case magicDNSSuffix = "MagicDNSSuffix"
            }
        }
        struct LocalDevice: Decodable {
            var hostName: String?
            var dnsName: String?
            var tailscaleIPs: [String]?
            var os: String?
            var keyExpiry: String?
            enum CodingKeys: String, CodingKey {
                case hostName = "HostName"
                case dnsName = "DNSName"
                case tailscaleIPs = "TailscaleIPs"
                case os = "OS"
                case keyExpiry = "KeyExpiry"
            }
        }
        struct PeerStatus: Decodable {
            var stableID: String
            var hostName: String
            var dnsName: String
            var online: Bool
            var inNetworkMap: Bool
            var shareeNode: Bool?
            var exitNodeOption: Bool?
            var sshHostKeys: [String]?
            var tailscaleIPs: [String]?
            var os: String?
            var keyExpiry: String?
            var lastSeen: String?
            enum CodingKeys: String, CodingKey {
                case stableID = "ID"
                case hostName = "HostName"
                case dnsName = "DNSName"
                case online = "Online"
                case inNetworkMap = "InNetworkMap"
                case shareeNode = "ShareeNode"
                case sshHostKeys
                case exitNodeOption = "ExitNodeOption"
                case tailscaleIPs = "TailscaleIPs"
                case os = "OS"
                case keyExpiry = "KeyExpiry"
                case lastSeen = "LastSeen"
            }
        }
    }
}
