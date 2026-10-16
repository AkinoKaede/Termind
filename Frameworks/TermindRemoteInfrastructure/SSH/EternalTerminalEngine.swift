import ETBootstrap
import ETSession
import Foundation
import TermindApplication
import TermindDomain

actor EternalTerminalEngine: ResumableTerminalEngine {
    // Keep the original flat payload keys: existing encrypted recovery files outlive app upgrades.
    struct Payload: Codable, Sendable {
        let clientID: String
        let passkey: Data
        let checkpoint: ETSessionCheckpoint
        let integration: RemoteShellIntegrationBootstrap?
        let commandFilter: RemoteCommandEventFilter?
        let integratedShell: ResumableTerminalShellState.IntegratedShell?
        let pendingIntegrationCommand: Data?

        var shellState: ResumableTerminalShellState {
            .init(
                integration: integration, commandFilter: commandFilter, integratedShell: integratedShell,
                pendingIntegrationCommand: pendingIntegrationCommand)
        }
    }

    private let receive: EventHandler
    private var session: ETTerminalSession?
    private var credentials: ETCredentials?
    private var bridge: TerminalTCPBridge?
    private var reader: Task<Void, Never>?
    private var observer: Task<Void, Never>?
    private var closed = false

    init(receive: @escaping EventHandler) {
        self.receive = receive
    }

    func prepare(_ context: ResumableTerminalEngineContext) async throws -> ResumableTerminalEnginePreparation {
        let payload = try context.checkpoint.map(Self.decodeCheckpoint)
        let socket = try await context.route()
        guard !closed else {
            socket.close()
            throw CancellationError()
        }
        let bridge = try TerminalTCPBridge(open: context.route, initial: socket)
        self.bridge = bridge
        if let payload {
            credentials = ETCredentials(clientID: payload.clientID, passkey: payload.passkey)
            session = try ETTerminalSession(
                host: "127.0.0.1", port: bridge.port, clientID: payload.clientID,
                passkey: payload.passkey, checkpoint: payload.checkpoint)
            return .init(shell: payload.shellState)
        }
        let executor = BootstrapExecutor(connection: context.bootstrap)
        do {
            credentials = try await ETBootstrap().run(using: executor)
        } catch {
            if let original = await executor.failure { throw original }
            throw TerminalTransportError.bootstrapFailed
        }
        try checkOpen()
        guard let credentials else { throw TerminalTransportError.bootstrapFailed }
        session = try ETTerminalSession(
            host: "127.0.0.1", port: bridge.port, clientID: credentials.clientID, passkey: credentials.passkey,
            environmentVariables: Dictionary(
                context.environment.map { ($0.variable, $0.value) }, uniquingKeysWith: { _, last in last }))
        var result = ResumableTerminalEnginePreparation(startupInput: try context.startup.eternalInput)
        if context.shellIntegrationEnabled && context.startup.plan == nil {
            let integration = RemoteShellIntegrationBootstrap()
            result.shell.integration = integration
            result.shell.commandFilter = RemoteCommandEventFilter(token: integration.token)
        }
        return result
    }

    static func decodeCheckpoint(_ payload: Data) throws -> Payload {
        try JSONDecoder().decode(Payload.self, from: payload)
    }

    func start(columns: UInt16, rows: UInt16) async throws {
        try checkOpen()
        guard let session else { throw TerminalTransportError.sessionFailed }
        startReaders(output: session.output, states: session.stateChanges)
        try await session.connect(initialDimensions: .init(rows: Int(rows), columns: Int(columns)))
        try checkOpen()
    }

    func startReaders(output: AsyncStream<Data>, states: AsyncStream<ETConnectionState>) {
        reader = Task { [weak self] in
            for await data in output {
                guard let self, !Task.isCancelled else { return }
                await self.deliver(data)
            }
        }
        observer = Task { [weak self] in
            for await state in states {
                guard let self, !Task.isCancelled else { return }
                await self.receiveState(state)
            }
        }
    }

    private func deliver(_ data: Data) async {
        guard !closed else { return }
        await receive(.output(data))
    }

    private func receiveState(_ state: ETConnectionState) async {
        guard !closed else { return }
        switch state {
        case .connected: await receive(.connected)
        case .reconnecting, .disconnected: await receive(.recovering)
        case .failed: await receive(.failed)
        case .sessionEnded:
            // Vendor output finishes first, but our consumer may still be draining it.
            await reader?.value
            guard !closed else { return }
            await receive(.ended)
        case .closed, .idle, .bootstrapping, .connecting: break
        }
    }

    func write(_ data: Data) async throws {
        try checkOpen()
        try await session?.send(data)
    }

    func resize(columns: UInt16, rows: UInt16) async throws {
        try checkOpen()
        try await session?.resize(rows: Int(rows), cols: Int(columns))
    }

    func checkpoint(shell: @Sendable () async -> ResumableTerminalShellState) async throws -> Data {
        try checkOpen()
        guard let session, let credentials else { throw TerminalTransportError.invalidCheckpoint }
        let checkpoint = try await session.prepareForApplicationBackground()
        let shell = await shell()
        return try JSONEncoder().encode(
            Payload(
                clientID: credentials.clientID, passkey: credentials.passkey, checkpoint: checkpoint,
                integration: shell.integration, commandFilter: shell.commandFilter,
                integratedShell: shell.integratedShell, pendingIntegrationCommand: shell.pendingIntegrationCommand))
    }

    func resume() async throws {
        try checkOpen()
        await session?.resumeFromApplicationBackground()
    }

    func prepareRetry() async {
        await bridge?.retry()
    }

    func retry() async throws {
        try checkOpen()
        await session?.notifyNetworkPathChanged()
    }

    func networkAvailable() async {
        await session?.notifyNetworkPathChanged()
    }

    func close() async {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        observer?.cancel()
        await session?.close()
        await bridge?.close()
        session = nil
        bridge = nil
        credentials = nil
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }
}

private actor BootstrapExecutor: ETBootstrapExecutor {
    let connection: SSHConnection
    private(set) var failure: (any Error)?
    init(connection: SSHConnection) { self.connection = connection }
    func run(command: String) async throws -> String {
        do {
            let result = try await connection.execute(
                command, workingDirectory: nil, stdin: nil, timeout: 20, outputLimit: 65_536, onOutput: nil)
            return result.stdout + result.stderr
        } catch {
            failure = error
            throw error
        }
    }
}
