import Foundation

public nonisolated struct DiscoveredLocalHost: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable { case bonjour, probe }
    public var name: String
    public var address: String
    public var port: Int
    public var source: Source
    public var connectionProtocol: LocalDiscoveryProtocol
    public var resolvedAddresses: Set<String>
    public var id: String { "\(connectionProtocol.rawValue)://\(address.lowercased()):\(port)" }

    public init(
        name: String, address: String, port: Int, source: Source,
        connectionProtocol: LocalDiscoveryProtocol = .ssh, resolvedAddresses: Set<String> = []
    ) {
        self.name = name
        self.address = address
        self.port = port
        self.source = source
        self.connectionProtocol = connectionProtocol
        self.resolvedAddresses = Set(resolvedAddresses.map { $0.lowercased() }).union([address.lowercased()])
    }

    public func prefill(_ host: inout Host) {
        guard !host.isTailscaleManaged else { return }
        host.name = name
        host.host = address
        switch connectionProtocol {
        case .ssh:
            host.sshPort = port
            host.sshEnabled = true
        case .telnet:
            host.telnetPort = port
            host.telnetEnabled = true
        }
    }

    public static func merged(_ results: [Self]) -> [Self] {
        var merged: [Self] = []
        let ordered = results.sorted {
            if $0.source != $1.source { return $0.source == .bonjour }
            return $0.id < $1.id
        }
        for result in ordered {
            let matches = merged.indices.filter {
                merged[$0].port == result.port
                    && merged[$0].connectionProtocol == result.connectionProtocol
                    && !merged[$0].resolvedAddresses.isDisjoint(with: result.resolvedAddresses)
            }
            guard let first = matches.first else {
                merged.append(result)
                continue
            }
            var combined = merged[first]
            combined.resolvedAddresses.formUnion(result.resolvedAddresses)
            for index in matches.reversed() {
                combined.resolvedAddresses.formUnion(merged[index].resolvedAddresses)
                merged.remove(at: index)
            }
            merged.append(combined)
        }
        return merged.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
