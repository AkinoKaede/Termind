import Foundation

nonisolated struct PortForwardingRule: Identifiable, Codable, Hashable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case local, remote, dynamic
        nonisolated var id: String { rawValue }
    }

    var id: UUID = UUID()
    var hostID: Host.ID
    var kind: Kind = .local
    var bindHost: String = "127.0.0.1"
    var bindPort: Int = 8080
    var targetHost: String? = "localhost"
    var targetPort: Int? = 80
    var label: String = ""

    init(
        id: UUID = UUID(), hostID: Host.ID, kind: Kind = .local,
        bindHost: String = "127.0.0.1", bindPort: Int = 8080,
        targetHost: String? = "localhost", targetPort: Int? = 80,
        label: String = ""
    ) {
        self.id = id
        self.hostID = hostID
        self.kind = kind
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.targetHost = kind == .dynamic ? nil : targetHost
        self.targetPort = kind == .dynamic ? nil : targetPort
        self.label = label
    }

    var isValid: Bool {
        guard !bindHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (1...65_535).contains(bindPort)
        else { return false }
        if kind == .dynamic { return true }
        return targetHost?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && targetPort.map { (1...65_535).contains($0) } == true
    }

    var bindAddress: String { Self.address(bindHost, port: bindPort) }

    var summary: String {
        switch kind {
        case .local:
            "\(bindAddress) → \(Self.address(targetHost ?? "", port: targetPort ?? 0))"
        case .remote:
            String(localized: "SSH \(bindAddress) → This Mac \(Self.address(targetHost ?? "", port: targetPort ?? 0))")
        case .dynamic: "SOCKS5 \(bindAddress)"
        }
    }

    private static func address(_ host: String, port: Int) -> String {
        "\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }
}
