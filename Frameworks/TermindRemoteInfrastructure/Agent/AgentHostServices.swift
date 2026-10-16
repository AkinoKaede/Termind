import TermindApplication

/// The shared live host-facing services used by Assistant and the MCP bridge.
/// App shells register these services with their execution surfaces instead of
/// rebuilding the SSH/SFTP connection stack.
@MainActor
public struct AgentHostServices {
    public let resolver: AgentHostResolver
    public let connections: AgentConnectionPool
    public let authentication: AgentSSHAuthenticationRegistry
    public let background: AgentBackgroundCommands

    public init(
        resolver: AgentHostResolver,
        connections: AgentConnectionPool,
        authentication: AgentSSHAuthenticationRegistry,
        background: AgentBackgroundCommands
    ) {
        self.resolver = resolver
        self.connections = connections
        self.authentication = authentication
        self.background = background
    }

    public static func live(
        store: HostLibraryModel,
        coordinator: RemoteConnectionCoordinator = RemoteConnectionCoordinator(),
        sftpConcurrencyScheduler: SFTPConcurrencyScheduler = SFTPConcurrencyScheduler()
    ) -> AgentHostServices {
        let resolver = AgentHostResolver(store: store)
        return AgentHostServices(
            resolver: resolver,
            connections: AgentConnectionPool(
                configuration: { try await resolver.resolvedConfiguration(for: $0) },
                routeFingerprint: { try await resolver.resolvedRouteFingerprint(for: $0) },
                forwardingEnabled: { await store.host($0)?.agentForwardingEnabled == true },
                openConnection: { try await coordinator.connectConnection(using: $0) },
                openSFTP: { try await coordinator.connectSFTP(using: $0) },
                sftpConcurrencyScheduler: sftpConcurrencyScheduler
            ),
            authentication: AgentSSHAuthenticationRegistry(resolver: resolver),
            background: AgentBackgroundCommands()
        )
    }
}
