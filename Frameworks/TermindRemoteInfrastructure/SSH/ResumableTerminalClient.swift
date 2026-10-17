import Foundation
import Network
import TermindApplication
import TermindDomain

public actor ResumableTerminalClient: ResumableTerminalSession {
    public typealias RouteFactory = @Sendable () async throws -> SSHRoutedSocket
    public typealias StateHandler = @Sendable (ResumableTerminalState) -> Void

    private let transport: HostTerminalProtocol
    private let registry: ResumableTerminalEngineRegistry
    private let output: SSHPTYChannel.OutputHandler
    private let stateChanged: StateHandler
    private let integrationChanged: SSHPTYChannel.ShellIntegrationHandler
    private let lifecycleRequestEnqueued: (@Sendable () -> Void)?
    private var engine: (any ResumableTerminalEngine)?
    private var maintenance: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var hasObservedNetworkPath = false
    private var closed = false
    private var protocolSuspended = false
    private var recoveryNeedsCompletion = false
    private var suspendedCheckpoint: TerminalTransportCheckpoint?
    private var lifecycleOperations: [LifecycleOperation] = []
    private var lifecycleTask: Task<Void, Never>?
    private var engineState: ResumableTerminalState = .connecting
    private var state: ResumableTerminalState = .connecting
    private var integration: RemoteShellIntegrationBootstrap?
    private var commandFilter: RemoteCommandEventFilter?
    private var integratedShell: ResumableTerminalShellState.IntegratedShell?
    private var pendingCheckpoint: TerminalTransportCheckpoint?
    private var pendingIntegrationCommand: Data?
    private var sendsInFlight = 0
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var viewport: (columns: UInt16, rows: UInt16) = (80, 24)

    private var frozen: Bool {
        !lifecycleOperations.isEmpty || protocolSuspended || recoveryNeedsCompletion
    }

    private enum LifecycleAction {
        case suspend, resume, retry
    }

    private struct LifecycleRequest {
        let id: UUID
        let continuation: CheckedContinuation<TerminalTransportCheckpoint?, any Error>
    }

    private struct LifecycleOperation {
        let id = UUID()
        let action: LifecycleAction
        var requests: [LifecycleRequest]
    }

    public init(
        transport: HostTerminalProtocol, checkpoint: TerminalTransportCheckpoint? = nil,
        output: @escaping SSHPTYChannel.OutputHandler,
        stateChanged: @escaping StateHandler,
        shellIntegration: @escaping SSHPTYChannel.ShellIntegrationHandler,
        registry: ResumableTerminalEngineRegistry = .live
    ) {
        self.init(
            transport: transport, checkpoint: checkpoint, output: output, stateChanged: stateChanged,
            shellIntegration: shellIntegration, registry: registry, pathMonitor: NWPathMonitor())
    }

    init(
        transport: HostTerminalProtocol, checkpoint: TerminalTransportCheckpoint? = nil,
        output: @escaping SSHPTYChannel.OutputHandler,
        stateChanged: @escaping StateHandler,
        shellIntegration: @escaping SSHPTYChannel.ShellIntegrationHandler,
        registry: ResumableTerminalEngineRegistry,
        pathMonitor: NWPathMonitor?,
        lifecycleRequestEnqueued: (@Sendable () -> Void)? = nil
    ) {
        self.transport = transport
        self.registry = registry
        self.pendingCheckpoint = checkpoint
        self.output = output
        self.stateChanged = stateChanged
        self.integrationChanged = shellIntegration
        self.pathMonitor = pathMonitor
        self.lifecycleRequestEnqueued = lifecycleRequestEnqueued
    }

    public func connect(
        request: SSHConnectionRequest, options: HostTerminalTransports,
        environment: [HostEnvironmentVariable], shellIntegrationEnabled: Bool,
        columns: UInt16, rows: UInt16, route: @escaping RouteFactory,
        progress: SSHRouteProgressHandler?,
        startupPreparation: SSHPTYChannel.StartupPreparation? = nil
    ) async throws {
        guard !closed, options.isValid, transport.isResumable else { throw CancellationError() }
        guard engine == nil else { throw TerminalTransportError.sessionFailed }
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
        // Reject an unregistered engine before wake, route, bootstrap or startup side effects.
        let engine = try registry.make(transport) { [weak self] event in
            await self?.receiveEngineEvent(event)
        }
        self.engine = engine
        sendsInFlight += 1
        defer { finishSend() }
        let bootstrap = SSHConnection()
        do {
            try checkOpen()
            try request.configuration.accessCheck?()
            await request.configuration.beforeConnect?()
            try checkOpen()
            publish(.connecting)
            if pendingCheckpoint == nil {
                try await bootstrap.connect(using: request, progress: progress, connectionFailure: nil)
                try checkOpen()
            }
            let startup = try await ResumableTerminalStartup.prepare(
                restoring: pendingCheckpoint != nil, preparation: startupPreparation,
                execute: { command in try await TerminalTransportRoute.execute(command, on: bootstrap) })
            try checkOpen()
            let preparation = try await engine.prepare(
                .init(
                    request: request, options: options, environment: environment,
                    shellIntegrationEnabled: shellIntegrationEnabled, checkpoint: pendingCheckpoint?.payload,
                    startup: startup, bootstrap: bootstrap, route: route))
            try checkOpen()
            integration = preparation.shell.integration
            commandFilter = preparation.shell.commandFilter
            integratedShell = preparation.shell.integratedShell
            pendingIntegrationCommand = preparation.shell.pendingIntegrationCommand
            if pendingCheckpoint != nil {
                integration?.resetDeadlinesAfterRestore()
                if let shell = integratedShell {
                    integrationChanged(
                        .available(shell: shell.shell, systemInfo: shell.systemInfo, homeDirectory: shell.homeDirectory)
                    )
                }
            }
            try await engine.start(columns: columns, rows: rows)
            try checkOpen()
            if let input = preparation.startupInput { try await engine.write(input) }
            if pendingCheckpoint == nil, let integration { try await engine.write(integration.startCommand) }
            if let command = pendingIntegrationCommand {
                pendingIntegrationCommand = nil
                try await engine.write(command)
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
            await engine.rollback(using: bootstrap)
            await bootstrap.disconnect()
            await close()
            throw error
        }
    }

    public func write(_ data: Data) async throws {
        try checkOpen()
        guard !frozen else { throw TerminalTransportError.suspended }
        integration?.noteUserInput()
        sendsInFlight += 1
        defer { finishSend() }
        try await engine?.write(data)
    }

    public func resize(columns: UInt16, rows: UInt16) async throws {
        try checkOpen()
        viewport = (columns, rows)
        guard !frozen else { return }
        sendsInFlight += 1
        defer { finishSend() }
        try await engine?.resize(columns: columns, rows: rows)
    }

    private var shellState: ResumableTerminalShellState {
        .init(
            integration: integration, commandFilter: commandFilter, integratedShell: integratedShell,
            pendingIntegrationCommand: pendingIntegrationCommand)
    }

    public func suspend() async throws -> TerminalTransportCheckpoint {
        guard let checkpoint = try await requestLifecycle(.suspend) else {
            throw TerminalTransportError.sessionFailed
        }
        return checkpoint
    }

    public func resume() async throws {
        _ = try await requestLifecycle(.resume)
    }

    public func retryNow() async throws {
        _ = try await requestLifecycle(.retry)
    }

    private func requestLifecycle(_ action: LifecycleAction) async throws -> TerminalTransportCheckpoint? {
        try checkOpen()
        guard engine != nil else { throw TerminalTransportError.sessionFailed }
        let id = UUID()
        let result: TerminalTransportCheckpoint? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<TerminalTransportCheckpoint?, any Error>) in
                guard !closed, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let request = LifecycleRequest(id: id, continuation: continuation)
                // Coalesce only adjacent matching requests; a checkpoint remains an ordering barrier.
                if let last = lifecycleOperations.indices.last,
                    lifecycleOperations[last].action == action
                {
                    lifecycleOperations[last].requests.append(request)
                } else {
                    lifecycleOperations.append(.init(action: action, requests: [request]))
                }
                lifecycleRequestEnqueued?()
                startNextLifecycleOperation()
            }
        } onCancel: {
            Task { await self.cancelLifecycleRequest(id) }
        }
        try Task.checkCancellation()
        return result
    }

    private func cancelLifecycleRequest(_ id: UUID) {
        guard let index = lifecycleOperations.firstIndex(where: { $0.requests.contains { $0.id == id } }),
            let requestIndex = lifecycleOperations[index].requests.firstIndex(where: { $0.id == id })
        else { return }
        let request = lifecycleOperations[index].requests.remove(at: requestIndex)
        request.continuation.resume(throwing: CancellationError())
        guard lifecycleOperations[index].requests.isEmpty else { return }
        // Admitted work belongs to the session: finish its barrier/flush even if every caller cancels.
        if index != 0 { lifecycleOperations.remove(at: index) }
    }

    private func startNextLifecycleOperation() {
        guard !closed, lifecycleTask == nil, let operation = lifecycleOperations.first else { return }
        lifecycleTask = Task { await self.runLifecycleOperation(operation) }
    }

    private func runLifecycleOperation(_ operation: LifecycleOperation) async {
        let result: Result<TerminalTransportCheckpoint?, any Error>
        do {
            try checkOpen()
            if sendsInFlight > 0 {
                await withCheckedContinuation { sendWaiters.append($0) }
            }
            try checkOpen()
            guard let engine else { throw CancellationError() }
            result = .success(try await performLifecycle(operation.action, engine: engine))
            try checkOpen()
        } catch {
            finishLifecycleOperation(operation.id, result: .failure(error))
            return
        }
        finishLifecycleOperation(operation.id, result: result)
    }

    private func finishLifecycleOperation(
        _ id: UUID, result: Result<TerminalTransportCheckpoint?, any Error>
    ) {
        guard lifecycleOperations.first?.id == id else { return }
        let operation = lifecycleOperations.removeFirst()
        lifecycleTask = nil
        if !frozen { publish(engineState) }
        for request in operation.requests { request.continuation.resume(with: result) }
        startNextLifecycleOperation()
    }

    private func performLifecycle(
        _ action: LifecycleAction, engine: any ResumableTerminalEngine
    ) async throws -> TerminalTransportCheckpoint? {
        if action == .suspend {
            if let suspendedCheckpoint { return suspendedCheckpoint }
            protocolSuspended = true
            // Capture shell state after protocol preparation, while every send path remains frozen.
            let payload = try await engine.checkpoint { await self.shellState }
            try checkOpen()
            let checkpoint = TerminalTransportCheckpoint(transport: transport, payload: payload)
            suspendedCheckpoint = checkpoint
            engineState = .suspended
            publish(.suspended)
            return checkpoint
        }
        recoveryNeedsCompletion = true
        if action == .retry || protocolSuspended { engineState = .recovering }
        if action == .retry {
            await engine.prepareRetry()
            try checkOpen()
        }
        if action == .resume || protocolSuspended {
            try await engine.beforeResume()
            try checkOpen()
            suspendedCheckpoint = nil
            publish(.recovering)
            try await engine.resume()
        } else {
            suspendedCheckpoint = nil
            publish(.recovering)
            try await engine.retry()
        }
        protocolSuspended = false
        try checkOpen()
        integration?.resetDeadlinesAfterRestore()
        var appliedViewport: (columns: UInt16, rows: UInt16)?
        // A resize or integration reply can arrive at each await; flush the newest state before admission reopens.
        while true {
            if appliedViewport?.columns != viewport.columns || appliedViewport?.rows != viewport.rows {
                let latest = viewport
                try await engine.resize(columns: latest.columns, rows: latest.rows)
                try checkOpen()
                appliedViewport = latest
            } else if let command = pendingIntegrationCommand {
                pendingIntegrationCommand = nil
                do {
                    try await engine.write(command)
                } catch {
                    if pendingIntegrationCommand == nil { pendingIntegrationCommand = command }
                    throw error
                }
                try checkOpen()
            } else {
                recoveryNeedsCompletion = false
                return nil
            }
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        lifecycleTask?.cancel()
        lifecycleTask = nil
        let operations = lifecycleOperations
        lifecycleOperations.removeAll()
        for operation in operations {
            for request in operation.requests { request.continuation.resume(throwing: CancellationError()) }
        }
        resumeSendWaiters()
        maintenance?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        await engine?.close()
        engine = nil
        pendingCheckpoint = nil
        suspendedCheckpoint = nil
        if state != .ended { publish(.closed) }
    }

    func receiveEngineEvent(_ event: ResumableTerminalEngineEvent) async {
        guard !closed else { return }
        switch event {
        case .output(let data): await receive(data)
        case .activity, .connected:
            engineState = .connected
            if !frozen { publish(.connected) }
        case .recovering:
            engineState = .recovering
            if !frozen { publish(.recovering) }
        case .failed:
            engineState = .failed
            publish(.failed)
        case .ended: await finishRemoteExit()
        }
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }

    private func finishSend() {
        sendsInFlight -= 1
        if sendsInFlight == 0 { resumeSendWaiters() }
    }

    private func resumeSendWaiters() {
        let waiters = sendWaiters
        sendWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
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

    private func receive(_ data: Data) async {
        guard !closed else { return }
        if var integration {
            let update = integration.receive(data)
            self.integration = update.isComplete ? nil : integration
            await apply(update)
        } else {
            deliverIntegratedOutput(data)
        }
    }

    private func apply(_ update: RemoteShellIntegrationBootstrap.Update) async {
        if let command = update.command {
            if frozen {
                pendingIntegrationCommand = command
            } else {
                sendsInFlight += 1
                do { try await engine?.write(command) } catch {
                    if !closed { publish(.failed) }
                }
                finishSend()
            }
        }
        guard !closed else { return }
        if update.integrationInstalled {
            let shell = ResumableTerminalShellState.IntegratedShell(
                shell: update.shell ?? "unknown", systemInfo: update.systemInfo, homeDirectory: update.homeDirectory)
            integratedShell = shell
            integrationChanged(
                .available(shell: shell.shell, systemInfo: shell.systemInfo, homeDirectory: shell.homeDirectory))
        }
        if update.homeResolutionUnavailable { integrationChanged(.homeResolutionUnavailable) }
        deliverIntegratedOutput(update.visibleOutput ?? Data())
    }

    private func deliverIntegratedOutput(_ data: Data) {
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
        guard let monitor = pathMonitor else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { await self?.networkPathChanged(available: available) }
        }
        monitor.start(queue: DispatchQueue(label: "com.akinokaede.termind.terminal-network"))
    }

    func networkPathChanged(available: Bool) async {
        let initial = !hasObservedNetworkPath
        hasObservedNetworkPath = true
        guard !closed, !frozen, state == .connected || state == .recovering else { return }
        if !available {
            engineState = .recovering
            publish(.recovering)
        }
        // Never bootstrap another shell: both engines retain their own protocol state.
        if available, !initial {
            sendsInFlight += 1
            defer { finishSend() }
            await engine?.networkAvailable()
        }
    }
}
