import Foundation
import TermindApplication
import TermindDomain

nonisolated enum ResumableTerminalEngineEvent: Sendable {
    case output(Data)
    case activity, connected, recovering, failed, ended
}

nonisolated struct ResumableTerminalShellState: Sendable {
    nonisolated struct IntegratedShell: Codable, Sendable {
        let shell: String
        let systemInfo: RemoteSystemInfo?
        let homeDirectory: String?
    }

    var integration: RemoteShellIntegrationBootstrap?
    var commandFilter: RemoteCommandEventFilter?
    var integratedShell: IntegratedShell?
    var pendingIntegrationCommand: Data?
}

nonisolated struct ResumableTerminalEnginePreparation: Sendable {
    var shell = ResumableTerminalShellState()
    var startupInput: Data?
}

nonisolated struct ResumableTerminalEngineContext: Sendable {
    let request: SSHConnectionRequest
    let options: HostTerminalTransports
    let environment: [HostEnvironmentVariable]
    let shellIntegrationEnabled: Bool
    let checkpoint: Data?
    let startup: ResumableTerminalStartup
    let bootstrap: SSHConnection
    let route: ResumableTerminalClient.RouteFactory
}

/// Engines own protocol resources, not application lifecycle or checkpoint eligibility.
/// Every event and integration write passes through the client's shared serialization barrier.
nonisolated protocol ResumableTerminalEngine: Sendable {
    typealias EventHandler = @Sendable (ResumableTerminalEngineEvent) async -> Void

    func prepare(_ context: ResumableTerminalEngineContext) async throws -> ResumableTerminalEnginePreparation
    func start(columns: UInt16, rows: UInt16) async throws
    func write(_ data: Data) async throws
    func resize(columns: UInt16, rows: UInt16) async throws
    func checkpoint(shell: @Sendable () async -> ResumableTerminalShellState) async throws -> Data
    func beforeResume() async throws
    func resume() async throws
    func prepareRetry() async
    func retry() async throws
    func networkAvailable() async
    func rollback(using bootstrap: SSHConnection) async
    func close() async
}

extension ResumableTerminalEngine {
    func beforeResume() async throws {}
    func prepareRetry() async {}
    func networkAvailable() async {}
    func rollback(using bootstrap: SSHConnection) async {}
}

/// Registrations are immutable and local to a coordinator; no process-global overrides.
public nonisolated struct ResumableTerminalEngineRegistry: Sendable {
    typealias Factory = @Sendable (@escaping ResumableTerminalEngine.EventHandler) -> any ResumableTerminalEngine
    private let factories: [HostTerminalProtocol: Factory]

    init(factories: [HostTerminalProtocol: Factory]) {
        self.factories = factories
    }

    public static let live = Self(factories: [
        .mosh: { MoshTerminalEngine(receive: $0) },
        .eternalTerminal: { EternalTerminalEngine(receive: $0) },
    ])

    func make(
        _ transport: HostTerminalProtocol, receive: @escaping ResumableTerminalEngine.EventHandler
    ) throws -> any ResumableTerminalEngine {
        guard let factory = factories[transport] else { throw TerminalTransportError.unsupportedRoute }
        return factory(receive)
    }
}
