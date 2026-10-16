import ETBootstrap
import ETSession
import Foundation
import MoshBootstrap
import MoshCore
import Network
import TermindApplication
import TermindDomain

public actor ResumableTerminalClient: ResumableTerminalSession {
    public typealias RouteFactory = @Sendable () async throws -> SSHRoutedSocket
    public typealias StateHandler = @Sendable (ResumableTerminalState) -> Void

    private let transport: HostTerminalProtocol
    private let output: SSHPTYChannel.OutputHandler
    private let stateChanged: StateHandler
    private let integrationChanged: SSHPTYChannel.ShellIntegrationHandler
    private var mosh: MoshClientSession?
    private var eternal: ETTerminalSession?
    private var bridge: TerminalTCPBridge?
    private var reader: Task<Void, Never>?
    private var observer: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var beforeConnect: ConnectionWakeAction?
    private var closed = false
    private var frozen = false
    private var state: ResumableTerminalState = .connecting
    private var credentials: ETCredentials?
    private var integration: RemoteShellIntegrationBootstrap?
    private var commandFilter: RemoteCommandEventFilter?
    private var integratedShell: IntegratedShell?
    private var pendingCheckpoint: TerminalTransportCheckpoint?
    private var pendingIntegrationCommand: Data?
    private var sendsInFlight = 0
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var viewport: (columns: UInt16, rows: UInt16) = (80, 24)

    private struct EternalPayload: Codable {
        let clientID: String
        let passkey: Data
        let checkpoint: ETSessionCheckpoint
        let integration: RemoteShellIntegrationBootstrap?
        let commandFilter: RemoteCommandEventFilter?
        let integratedShell: IntegratedShell?
        let pendingIntegrationCommand: Data?
    }

    private struct IntegratedShell: Codable {
        let shell: String
        let systemInfo: RemoteSystemInfo?
        let homeDirectory: String?
    }

    public init(
        transport: HostTerminalProtocol, checkpoint: TerminalTransportCheckpoint? = nil,
        output: @escaping SSHPTYChannel.OutputHandler,
        stateChanged: @escaping StateHandler,
        shellIntegration: @escaping SSHPTYChannel.ShellIntegrationHandler
    ) {
        self.transport = transport
        self.pendingCheckpoint = checkpoint
        self.output = output
        self.stateChanged = stateChanged
        self.integrationChanged = shellIntegration
    }

    public func connect(
        request: SSHConnectionRequest, options: HostTerminalTransports,
        environment: [HostEnvironmentVariable], shellIntegrationEnabled: Bool,
        columns: UInt16, rows: UInt16, route: @escaping RouteFactory,
        progress: SSHRouteProgressHandler?,
        startupPreparation: SSHPTYChannel.StartupPreparation? = nil
    ) async throws {
        guard !closed, options.isValid, transport.isResumable else { throw CancellationError() }
        viewport = (columns, rows)
        guard options.available(isTailscaleManaged: request.configuration.network != nil).contains(transport) else {
            throw TerminalTransportError.unsupportedRoute
        }
        guard environment.allSatisfy(\.isValid) else { throw TerminalTransportError.bootstrapFailed }
        if let pendingCheckpoint,
            pendingCheckpoint.version != 1 || pendingCheckpoint.transport != transport
        {
            throw TerminalTransportError.invalidCheckpoint
        }
        beforeConnect = request.configuration.beforeConnect
        try Task.checkCancellation()
        await request.configuration.beforeConnect?()
        try Task.checkCancellation()
        publish(.connecting)
        sendsInFlight += 1
        defer { finishSend() }
        let bootstrap = SSHConnection()
        var rollbackMoshPID: Int32?
        do {
            if pendingCheckpoint == nil {
                try await bootstrap.connect(using: request, progress: progress, connectionFailure: nil)
                try checkOpen()
            }
            let startup = try await ResumableTerminalStartup.prepare(
                restoring: pendingCheckpoint != nil, preparation: startupPreparation,
                execute: { command in try await TerminalTransportRoute.execute(command, on: bootstrap) })
            try checkOpen()
            if let checkpoint = pendingCheckpoint {
                try await restore(checkpoint, route: route)
            } else {
                if transport == .mosh {
                    let range = options.moshUDPPortRange.replacingOccurrences(of: "-", with: ":")
                    var command = "mosh-server new -s -c 256"
                    if !range.isEmpty { command += " -p \(range)" }
                    command += try startup.moshArguments
                    let variables = environment.map {
                        "'\($0.variable)=\($0.value.replacingOccurrences(of: "'", with: "'\\''"))'"
                    }
                    command = (["env"] + variables + ["LANG=C.UTF-8", "LC_ALL=C.UTF-8", command])
                        .joined(separator: " ")
                    let result = try await bootstrap.execute(
                        command, workingDirectory: nil, stdin: nil, timeout: 20, outputLimit: 65_536, onOutput: nil)
                    let info: MoshServerConnectInfo
                    do {
                        info = try MoshServerOutputParser.parse(result.stdout + result.stderr)
                    } catch {
                        throw TerminalTransportError.bootstrapFailed
                    }
                    rollbackMoshPID = info.serverPID
                    mosh = MoshClientSession(
                        endpoint: .init(
                            host: request.configuration.host, port: info.port, keyBase64_22: info.key))
                } else {
                    let bridge = try TerminalTCPBridge(open: route, initial: await route())
                    self.bridge = bridge
                    let executor = BootstrapExecutor(connection: bootstrap)
                    do {
                        credentials = try await ETBootstrap().run(using: executor)
                    } catch {
                        if let original = await executor.failure { throw original }
                        throw TerminalTransportError.bootstrapFailed
                    }
                    try checkOpen()
                    guard let credentials else { throw TerminalTransportError.bootstrapFailed }
                    eternal = try ETTerminalSession(
                        host: "127.0.0.1", port: bridge.port,
                        clientID: credentials.clientID, passkey: credentials.passkey,
                        environmentVariables: Dictionary(
                            environment.map { ($0.variable, $0.value) },
                            uniquingKeysWith: { _, last in last }))
                    if shellIntegrationEnabled && startup.plan == nil {
                        let integration = RemoteShellIntegrationBootstrap()
                        self.integration = integration
                        commandFilter = RemoteCommandEventFilter(token: integration.token)
                    }
                }
            }
            try checkOpen()
            if let mosh {
                try await mosh.start()
                try await mosh.enqueue(.resize(cols: Int32(columns), rows: Int32(rows)))
                // An open UDP socket is not proof that the server is reachable.
                let deadline = ContinuousClock.now.advanced(by: .seconds(20))
                while true {
                    try checkOpen()
                    let operations = await mosh.drainHostOps()
                    if !operations.isEmpty {
                        deliver(operations)
                        break
                    }
                    let state = await mosh.state
                    if case .failed = state { throw TerminalTransportError.sessionFailed }
                    if state == .stopped {
                        rollbackMoshPID = nil
                        _ = await receiveMoshPoll(state: state, operations: mosh.drainHostOps())
                        await bootstrap.disconnect()
                        return
                    }
                    guard ContinuousClock.now < deadline else { throw TerminalTransportError.unreachable }
                    try await Task.sleep(for: .milliseconds(20))
                }
                rollbackMoshPID = nil
                publish(.connected)
                startMoshReader(mosh)
            } else if let eternal {
                startEternalReaders(eternal)
                try await eternal.connect(initialDimensions: .init(rows: Int(rows), columns: Int(columns)))
                try checkOpen()
                if let input = try startup.eternalInput {
                    try await eternal.send(input)
                }
                if pendingCheckpoint == nil, let integration { try await eternal.send(integration.startCommand) }
                if let command = pendingIntegrationCommand {
                    pendingIntegrationCommand = nil
                    try await eternal.send(command)
                }
            }
            await bootstrap.disconnect()
            pendingCheckpoint = nil
            guard !closed else { return }
            startMaintenance()
            startNetworkMonitoring()
        } catch {
            if state == .ended {
                await bootstrap.disconnect()
                return
            }
            if let pid = rollbackMoshPID, pid > 1 {
                // Only undo the server this attempt just launched; never kill a user's other sessions.
                await Task.detached {
                    _ = try? await bootstrap.execute(
                        "[ \"$(ps -p \(pid) -o comm=)\" = mosh-server ] && kill -TERM \(pid)",
                        workingDirectory: nil, stdin: nil, timeout: 3, outputLimit: 1024, onOutput: nil)
                }.value
            }
            await bootstrap.disconnect()
            await close()
            throw error
        }
    }

    private func restore(_ checkpoint: TerminalTransportCheckpoint, route: @escaping RouteFactory) async throws {
        if transport == .mosh {
            let snapshot = try JSONDecoder().decode(MoshSnapshot.self, from: checkpoint.payload)
            mosh = try await MoshClientSession.restore(from: snapshot)
        } else {
            let payload = try JSONDecoder().decode(EternalPayload.self, from: checkpoint.payload)
            credentials = ETCredentials(clientID: payload.clientID, passkey: payload.passkey)
            let bridge = try TerminalTCPBridge(open: route, initial: await route())
            self.bridge = bridge
            eternal = try ETTerminalSession(
                host: "127.0.0.1", port: bridge.port, clientID: payload.clientID,
                passkey: payload.passkey, checkpoint: payload.checkpoint)
            integration = payload.integration
            integration?.resetDeadlinesAfterRestore()
            commandFilter = payload.commandFilter
            integratedShell = payload.integratedShell
            pendingIntegrationCommand = payload.pendingIntegrationCommand
            if let shell = integratedShell {
                integrationChanged(
                    .available(shell: shell.shell, systemInfo: shell.systemInfo, homeDirectory: shell.homeDirectory))
            }
        }
    }

    public func write(_ data: Data) async throws {
        try checkOpen()
        guard !frozen else { throw TerminalTransportError.suspended }
        integration?.noteUserInput()
        sendsInFlight += 1
        defer { finishSend() }
        if let mosh { try await mosh.enqueue(.keystrokes(data)) }
        if let eternal { try await eternal.send(data) }
    }

    public func resize(columns: UInt16, rows: UInt16) async throws {
        try checkOpen()
        viewport = (columns, rows)
        guard !frozen else { return }
        sendsInFlight += 1
        defer { finishSend() }
        if let mosh { try await mosh.enqueue(.resize(cols: Int32(columns), rows: Int32(rows))) }
        if let eternal { try await eternal.resize(rows: Int(rows), cols: Int(columns)) }
    }

    public func suspend() async throws -> TerminalTransportCheckpoint {
        try checkOpen()
        guard state == .connected || state == .recovering else { throw TerminalTransportError.sessionFailed }
        frozen = true
        if sendsInFlight > 0 {
            await withCheckedContinuation { sendWaiters.append($0) }
        }
        try checkOpen()
        let payload: Data
        if let mosh {
            payload = try JSONEncoder().encode(await mosh.prepareForApplicationBackground())
        } else if let eternal, let credentials {
            let checkpoint = try await eternal.prepareForApplicationBackground()
            payload = try JSONEncoder().encode(
                EternalPayload(
                    clientID: credentials.clientID, passkey: credentials.passkey,
                    checkpoint: checkpoint, integration: integration, commandFilter: commandFilter,
                    integratedShell: integratedShell, pendingIntegrationCommand: pendingIntegrationCommand))
        } else {
            throw TerminalTransportError.invalidCheckpoint
        }
        try checkOpen()
        publish(.suspended)
        return TerminalTransportCheckpoint(transport: transport, payload: payload)
    }

    public func resume() async throws {
        try checkOpen()
        if mosh != nil {
            await beforeConnect?()
            try checkOpen()
        }
        frozen = false
        publish(.recovering)
        if let mosh { try await mosh.resumeFromApplicationBackground() }
        if let eternal { await eternal.resumeFromApplicationBackground() }
        try checkOpen()
        integration?.resetDeadlinesAfterRestore()
        try await resize(columns: viewport.columns, rows: viewport.rows)
        if let command = pendingIntegrationCommand {
            pendingIntegrationCommand = nil
            sendsInFlight += 1
            defer { finishSend() }
            try await eternal?.send(command)
        }
    }

    public func retryNow() async throws {
        try checkOpen()
        await bridge?.retry()
        if frozen {
            try await resume()
            return
        }
        if let eternal { await eternal.notifyNetworkPathChanged() }
        if let mosh {
            await beforeConnect?()
            try checkOpen()
            _ = try await mosh.prepareForApplicationBackground()
            try await mosh.resumeFromApplicationBackground()
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        observer?.cancel()
        maintenance?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        beforeConnect = nil
        if let mosh { await mosh.stop() }
        if let eternal { await eternal.close() }
        await bridge?.close()
        mosh = nil
        eternal = nil
        bridge = nil
        credentials = nil
        pendingCheckpoint = nil
        if state != .ended { publish(.closed) }
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }

    private func finishSend() {
        sendsInFlight -= 1
        if sendsInFlight == 0 {
            let waiters = sendWaiters
            sendWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private func publish(_ next: ResumableTerminalState) {
        guard !closed || next == .closed, state != .ended, state != next else { return }
        state = next
        stateChanged(next)
    }

    private func finishRemoteExit() async {
        guard !closed, state != .ended else { return }
        publish(.ended)
        await close()
    }

    private func startMoshReader(_ session: MoshClientSession) {
        reader = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Read terminal state before draining, so the final poll cannot miss trailing output.
                let state = await session.state
                guard await self.receiveMoshPoll(state: state, operations: session.drainHostOps()) else { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func receiveMoshPoll(state: MoshSessionState, operations: [MoshHostOp]) async -> Bool {
        guard !closed else { return false }
        deliver(operations)
        switch state {
        case .stopped:
            // Remote shutdown reaches this state only with swift-mosh's shutdown-marker fix (PR #2).
            await finishRemoteExit()
            return false
        case .failed:
            publish(.failed)
            return false
        case .idle, .starting, .running, .suspending, .suspended, .stopping:
            return true
        }
    }

    private func deliver(_ operations: [MoshHostOp]) {
        guard !closed else { return }
        if !operations.isEmpty, !frozen { publish(.connected) }
        for operation in operations {
            if case .hostBytes(let data) = operation { output(data) }
        }
    }

    private func startEternalReaders(_ session: ETTerminalSession) {
        startEternalReaders(output: session.output, states: session.stateChanges)
    }

    func startEternalReaders(output: AsyncStream<Data>, states: AsyncStream<ETConnectionState>) {
        reader = Task { [weak self] in
            for await data in output {
                guard let self, !Task.isCancelled else { return }
                await self.receive(data)
            }
        }
        observer = Task { [weak self] in
            for await state in states {
                guard let self, !Task.isCancelled else { return }
                await self.receiveEternalState(state)
            }
        }
    }

    private func receiveEternalState(_ state: ETConnectionState) async {
        guard !closed else { return }
        switch state {
        case .connected:
            if !frozen { publish(.connected) }
        case .reconnecting, .disconnected:
            if !frozen { publish(.recovering) }
        case .failed: publish(.failed)
        case .sessionEnded:
            // The vendor finishes output before emitting this state, but our consumer may still be draining it.
            await reader?.value
            await finishRemoteExit()
        case .closed, .idle, .bootstrapping, .connecting: break
        }
    }

    private func receive(_ data: Data) async {
        guard !closed else { return }
        if var integration {
            let update = integration.receive(data)
            self.integration = update.isComplete ? nil : integration
            await apply(update)
        } else {
            deliverEternalOutput(data)
        }
    }

    private func apply(_ update: RemoteShellIntegrationBootstrap.Update) async {
        if let command = update.command {
            if frozen {
                pendingIntegrationCommand = command
            } else {
                sendsInFlight += 1
                do { try await eternal?.send(command) } catch {
                    if !closed { publish(.failed) }
                }
                finishSend()
            }
        }
        guard !closed else { return }
        if update.integrationInstalled {
            let shell = IntegratedShell(
                shell: update.shell ?? "unknown", systemInfo: update.systemInfo, homeDirectory: update.homeDirectory)
            integratedShell = shell
            integrationChanged(
                .available(shell: shell.shell, systemInfo: shell.systemInfo, homeDirectory: shell.homeDirectory))
        }
        if update.homeResolutionUnavailable { integrationChanged(.homeResolutionUnavailable) }
        deliverEternalOutput(update.visibleOutput ?? Data())
    }

    private func deliverEternalOutput(_ data: Data) {
        guard !closed else { return }
        var visible = data
        if var commandFilter {
            let update = commandFilter.receive(visible)
            self.commandFilter = commandFilter
            visible = update.visibleOutput
            for event in update.events {
                switch event {
                case .commandStarted(let command): integrationChanged(.commandStarted(command))
                case .commandFinished(let code, let duration):
                    integrationChanged(.commandFinished(code, duration: duration))
                case .promptReady: integrationChanged(.promptReady)
                case .draft(let draft): integrationChanged(.draft(draft))
                }
            }
        }
        if !visible.isEmpty { output(visible) }
    }

    private func startMaintenance() {
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                await self?.pollIntegration()
            }
        }
    }

    private func pollIntegration() async {
        guard !closed, !frozen, var integration else { return }
        let update = integration.poll()
        self.integration = update.isComplete ? nil : integration
        await apply(update)
    }

    private func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { await self?.networkPathChanged(available: available) }
        }
        monitor.start(queue: DispatchQueue(label: "com.akinokaede.termind.terminal-network"))
        pathMonitor = monitor
    }

    private func networkPathChanged(available: Bool) async {
        guard !closed, !frozen, state == .connected || state == .recovering else { return }
        if !available { publish(.recovering) }
        // Never bootstrap another shell: both engines retain their own protocol state.
        if available { await eternal?.notifyNetworkPathChanged() }
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
