import Foundation

public nonisolated struct PortForwardingRule: Identifiable, Codable, Hashable, Sendable {
    public nonisolated enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case local, remote, dynamic
        public nonisolated var id: String { rawValue }
    }

    public var id: UUID = UUID()
    public var hostID: Host.ID
    public var kind: Kind = .local
    public var bindHost: String = "127.0.0.1"
    public var bindPort: Int = 8080
    public var targetHost: String? = "localhost"
    public var targetPort: Int? = 80
    public var label: String = ""
    public var colorTag: TagColor = .none

    public init(
        id: UUID = UUID(), hostID: Host.ID, kind: Kind = .local,
        bindHost: String = "127.0.0.1", bindPort: Int = 8080,
        targetHost: String? = "localhost", targetPort: Int? = 80,
        label: String = "", colorTag: TagColor = .none
    ) {
        self.id = id
        self.hostID = hostID
        self.kind = kind
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.targetHost = kind == .dynamic ? nil : targetHost
        self.targetPort = kind == .dynamic ? nil : targetPort
        self.label = label
        self.colorTag = colorTag
    }

    private enum CodingKeys: String, CodingKey {
        case id, hostID, kind, bindHost, bindPort, targetHost, targetPort, label, colorTag
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            hostID: try values.decode(UUID.self, forKey: .hostID),
            kind: try values.decode(Kind.self, forKey: .kind),
            bindHost: try values.decode(String.self, forKey: .bindHost),
            bindPort: try values.decode(Int.self, forKey: .bindPort),
            targetHost: try values.decodeIfPresent(String.self, forKey: .targetHost),
            targetPort: try values.decodeIfPresent(Int.self, forKey: .targetPort),
            label: try values.decode(String.self, forKey: .label),
            colorTag: (try? values.decode(TagColor.self, forKey: .colorTag)) ?? .none)
    }

    public var isValid: Bool {
        guard !bindHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (1...65_535).contains(bindPort)
        else { return false }
        if kind == .dynamic { return true }
        return targetHost?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && targetPort.map { (1...65_535).contains($0) } == true
    }

    public var bindAddress: String { Self.address(bindHost, port: bindPort) }

    public var summary: String {
        switch kind {
        case .local:
            "\(bindAddress) → \(Self.address(targetHost ?? "", port: targetPort ?? 0))"
        case .remote:
            String(
                localized: "SSH \(bindAddress) → This Device \(Self.address(targetHost ?? "", port: targetPort ?? 0))")
        case .dynamic: "SOCKS5 \(bindAddress)"
        }
    }

    private static func address(_ host: String, port: Int) -> String {
        "\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }
}
