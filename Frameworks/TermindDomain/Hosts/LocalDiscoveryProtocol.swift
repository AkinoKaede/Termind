public nonisolated enum LocalDiscoveryProtocol: String, Sendable {
    case ssh
    case telnet

    public init?(terminalProtocol: HostTerminalProtocol) {
        switch terminalProtocol {
        case .ssh: self = .ssh
        case .telnet: self = .telnet
        case .mosh, .eternalTerminal: return nil
        }
    }

    public var terminalProtocol: HostTerminalProtocol {
        switch self {
        case .ssh: .ssh
        case .telnet: .telnet
        }
    }

    public var port: Int { terminalProtocol.defaultPort }
}
