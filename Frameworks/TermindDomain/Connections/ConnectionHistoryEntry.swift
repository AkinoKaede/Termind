import Foundation

/// One user-initiated connection to a saved Host.
///
/// Every attempt is retained as its own event so the History sidebar can show
/// repeated visits to the same destination.
public nonisolated struct ConnectionHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    /// Saved remote-host protocols only. Local Serial sessions have no Host.ID,
    /// and TFI does not expose Serial workspaces, so they never enter this timeline.
    public nonisolated enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case ssh
        case mosh
        case eternalTerminal
        case telnet
        case sftp

        public var terminalProtocol: HostTerminalProtocol? {
            switch self {
            case .ssh: .ssh
            case .telnet: .telnet
            case .mosh: .mosh
            case .eternalTerminal: .eternalTerminal
            case .sftp: nil
            }
        }

        public var isSSHTerminal: Bool { self == .ssh || self == .mosh || self == .eternalTerminal }

        public static func terminal(_ transport: HostTerminalProtocol) -> Self {
            switch transport {
            case .ssh: .ssh
            case .telnet: .telnet
            case .mosh: .mosh
            case .eternalTerminal: .eternalTerminal
            }
        }

        public static func preferredTerminal(for host: Host) -> Self? {
            host.preferredTerminalProtocol.map(terminal)
        }

        public var label: String {
            switch self {
            case .ssh: String(localized: "SSH")
            case .telnet: String(localized: "Telnet")
            case .sftp: String(localized: "SFTP")
            case .mosh: "Mosh"
            case .eternalTerminal: "Eternal Terminal"
            }
        }

        public var symbol: String {
            switch self {
            case .ssh: "terminal"
            case .mosh: HostTerminalProtocol.mosh.symbol
            case .eternalTerminal: HostTerminalProtocol.eternalTerminal.symbol
            case .telnet: "text.rectangle"
            case .sftp: "folder"
            }
        }
    }

    public var id: UUID = UUID()
    public var hostID: Host.ID
    public var kind: Kind
    public var connectedAt: Date = Date()
    /// Stable installation identity used to resolve the synchronized source-device record.
    public var sourceDeviceID: UUID?
    /// Nil while the workspace or pane opened by this event remains in use.
    public var endedAt: Date?

    public init(
        id: UUID = UUID(), hostID: Host.ID, kind: Kind, connectedAt: Date = Date(),
        sourceDeviceID: UUID? = nil, endedAt: Date? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.kind = kind
        self.connectedAt = connectedAt
        self.sourceDeviceID = sourceDeviceID
        self.endedAt = endedAt
    }

}
