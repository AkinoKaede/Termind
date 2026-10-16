import Foundation

/// SSH authenticates every transport here. These options never affect auxiliary SSH services.
public nonisolated struct HostTerminalTransports: Codable, Hashable, Sendable {
    public var defaultTransport: HostTerminalProtocol = .ssh
    public var moshEnabled = false
    public var eternalTerminalEnabled = false
    public var moshUDPPortRange = ""
    public var eternalTerminalPort = 2022

    public init() {}

    public func available(isTailscaleManaged: Bool) -> [HostTerminalProtocol] {
        [.ssh] + (moshEnabled && !isTailscaleManaged ? [.mosh] : [])
            + (eternalTerminalEnabled ? [.eternalTerminal] : [])
    }

    public func preferred(isTailscaleManaged: Bool) -> HostTerminalProtocol {
        available(isTailscaleManaged: isTailscaleManaged).contains(defaultTransport) ? defaultTransport : .ssh
    }

    public mutating func normalizeDefault(isTailscaleManaged: Bool) {
        defaultTransport = preferred(isTailscaleManaged: isTailscaleManaged)
    }

    public var isValid: Bool {
        (!moshEnabled || Self.isValidMoshPortRange(moshUDPPortRange))
            && (!eternalTerminalEnabled || (1...65_535).contains(eternalTerminalPort))
            && defaultTransport != .telnet
    }

    /// Accept only a port or inclusive range; never interpolate arbitrary text into the bootstrap command.
    public static func isValidMoshPortRange(_ value: String) -> Bool {
        if value.isEmpty { return true }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
            parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
            let first = Int(parts[0]), (1...65_535).contains(first)
        else { return false }
        guard parts.count == 2 else { return true }
        guard let last = Int(parts[1]) else { return false }
        return (first...65_535).contains(last)
    }
}
