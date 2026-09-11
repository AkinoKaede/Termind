import Combine
import Foundation
import GhosttyTerminal
import Observation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindRemoteInfrastructure

import struct TermindDomain.Host

@MainActor
struct MobileWorkspaceConnectionServices {
    var discoverHostKey:
        (Host.ID, String, Int, SSHTransportProxy?, [SSHRouteHopConfiguration]) async throws -> SSHHostKeyObservation
    var makeSSHSession:
        (
            @escaping SSHSessionActor.OutputHandler, @escaping SSHSessionActor.ExitHandler,
            @escaping SSHSessionActor.ShellIntegrationHandler
        ) -> SSHSessionActor
    var connectSSH:
        (
            SSHSessionActor, SSHConnectionConfiguration, Bool, UInt16, UInt16,
            SSHRouteProgressHandler?
        ) async throws -> Void
    var connectSFTP:
        (
            SSHConnectionConfiguration, SSHRouteProgressHandler?,
            (@Sendable (String) -> Void)?
        ) async throws -> any SFTPClientProtocol
    var writeSSH: (SSHSessionActor, Data) async -> Void

    static var live: MobileWorkspaceConnectionServices {
        let coordinator = RemoteConnectionCoordinator()
        return MobileWorkspaceConnectionServices(
            discoverHostKey: { hostID, host, port, proxy, jumps in
                try await SSHSessionActor.discoverHostKey(
                    hostID: hostID, host: host, port: port, proxy: proxy, jumps: jumps)
            },
            makeSSHSession: { output, exit, shellIntegration in
                coordinator.makeSSHSession(output: output, exit: exit, shellIntegration: shellIntegration)
            },
            connectSSH: { session, configuration, shellIntegrationEnabled, columns, rows, progress in
                try await session.connect(
                    hostID: configuration.hostID,
                    host: configuration.host,
                    port: configuration.port,
                    username: configuration.username,
                    credentials: configuration.credentials,
                    expectedHostKeys: configuration.expectedHostKeys,
                    proxy: configuration.proxy,
                    jumps: configuration.jumps,
                    shellIntegrationEnabled: shellIntegrationEnabled,
                    columns: columns,
                    rows: rows,
                    progress: progress
                )
            },
            connectSFTP: { configuration, progress, connectionFailure in
                try await coordinator.connectSFTP(
                    using: configuration, progress: progress, connectionFailure: connectionFailure)
            },
            writeSSH: { session, data in await session.write(data) })
    }
}

private enum MobileWorkspaceConnectionResumeIntent: Equatable {
    case none
    case whenOpened
    case foreground
}

private struct MobilePendingDraftRequest {
    var id: UUID
    var continuation: CheckedContinuation<String, any Error>
}

nonisolated enum MobileUploadNotice: Equatable, Sendable {
    case preparing(String)
    case queued(Int, String)
    case rejected(String)
}

private struct MobilePendingUpload {
    var batch: SFTPLocalUploadBatch
    var destination: String
    var client: any SFTPClientProtocol
    var ownsClient: Bool
    var configuration: SSHConnectionConfiguration
    var connectionGeneration: UUID
}

@MainActor
@Observable
final class MobileWorkspace: Identifiable {
    typealias ID = UUID

    let descriptor: MobileWorkspaceDescriptor
    var id: UUID { descriptor.id }
    var detectedDistribution: DetectedDistribution? { hosts.host(descriptor.hostID)?.detectedDistribution }
    var didChangeState: (() -> Void)?
    private(set) var status = String(localized: "Disconnected") { didSet { didChangeState?() } }
    private(set) var connected = false { didSet { didChangeState?() } }
    private(set) var busy = false
    var reconnectState: ReconnectState? { reconnect.state }
    let journey = ConnectionJourney()
    var operationError: String?
    private var connectionFailure: String?
    private var pendingHostKeyHostID: UUID?
    private(set) var authenticationPrompt: SSHAuthenticationPrompt?
    private var authenticationMode = SSHAuthenticationPrompt.Mode.localIdentity
    var pendingHostKey: SSHHostKeyObservation?
    var authenticationRequired = false
    var username = ""
    private var authenticationHostID: UUID?
    private var temporaryKeys: [UUID: SSHHostKeyIdentity] = [:]
    private var submissions: [UUID: SSHAuthenticationSubmission] = [:]
    var path = "/"
    private(set) var files: [RemoteFile] = []
    let transfers: SFTPTransferCoordinator?
    private var transferConfiguration: SSHConnectionConfiguration?
    private var directoryRequest = UUID()
    private(set) var uploadNotice: MobileUploadNotice?
    private var pendingUpload: MobilePendingUpload?
    private var uploadPreparationTask: Task<Void, Never>?
    private var uploadEnqueueTask: Task<Void, Never>?
    private var uploadNoticeTask: Task<Void, Never>?
    let terminalSettings: TerminalSettingsModel
    let commandHistory: CommandHistoryModel
    var isFindPresented = false
    var findQuery = ""
    private var activeHistoryID: UUID?
    private var shellIntegrationAvailable = false
    private(set) var pendingInitialCommand: String?
    private(set) var workingDirectory: String?
    private(set) var commandGeneratorState: CommandGeneratorState = .idle
    private var integratedShell: String?
    private var remoteSystemInfo: RemoteSystemInfo?
    private var isShellPromptReady = false
    private var commandGeneratorRevision: UInt64 = 0
    private var commandGenerationSequence: UInt64 = 0
    private var commandGeneratorTask: Task<Void, Never>?
    private var commandGeneratorDismissTask: Task<Void, Never>?
    private var pendingDraftRequest: MobilePendingDraftRequest?
    private var draftRequestTimeoutTask: Task<Void, Never>?
    private var workingDirectoryObservation: AnyCancellable?
    private let surfaceOwner = MobileTerminalSurface()
    let terminal: TerminalViewState
    private let backend: InMemoryTerminalSession
    private var ssh: SSHSessionActor?
    private var sftp: (any SFTPClientProtocol)?
    private var attempt: Task<Void, Never>?
    private var generation = UUID()
    private let hosts: any RemoteSessionHostStore
    private let connectionServices: MobileWorkspaceConnectionServices
    private let reconnect: MobileWorkspaceReconnectState
    private var viewport = InMemoryTerminalViewport(columns: 80, rows: 24)

    var uploadConflictCount: Int { pendingUpload?.batch.conflictCount ?? 0 }
    var hasPendingUploadConflict: Bool { uploadConflictCount > 0 }

    var uploadDestination: String? {
        switch descriptor.kind {
        case .ssh:
            guard uploadTargetProblem == nil, let workingDirectory else { return nil }
            return RemotePath.normalized(workingDirectory)
        case .sftp:
            guard uploadTargetProblem == nil else { return nil }
            return path
        }
    }

    var uploadTargetProblem: String? {
        guard connected, transferConfiguration != nil else {
            return descriptor.kind == .ssh
                ? String(localized: "The SSH session is not ready for file transfer.")
                : String(localized: "The SFTP session is not connected.")
        }
        if descriptor.kind == .ssh,
            workingDirectory == nil || workingDirectory?.isEmpty == true
        {
            return String(localized: "Wait for the shell prompt to report its current directory.")
        }
        if descriptor.kind == .sftp, sftp == nil {
            return String(localized: "The SFTP session is not connected.")
        }
        return nil
    }
    private var connectionResumeIntent: MobileWorkspaceConnectionResumeIntent

    init(
        descriptor: MobileWorkspaceDescriptor, hosts: any RemoteSessionHostStore,
        transfers: SFTPTransferCoordinator? = nil,
        terminalSettings: TerminalSettingsModel = TerminalSettingsModel(),
        commandHistory: CommandHistoryModel = CommandHistoryModel(),
        connectionServices: MobileWorkspaceConnectionServices = .live,
        reconnectController: SessionReconnectController = SessionReconnectController(),
        initialCommand: String? = nil,
        connectsWhenOpened: Bool = false
    ) {
        self.terminalSettings = terminalSettings
        self.commandHistory = commandHistory
        self.transfers = transfers
        self.descriptor = descriptor
        self.hosts = hosts
        pendingInitialCommand = initialCommand
        self.connectionServices = connectionServices
        reconnect = MobileWorkspaceReconnectState(controller: reconnectController)
        connectionResumeIntent = connectsWhenOpened ? .whenOpened : .none
        let relay = MobileTerminalRelay()
        backend = InMemoryTerminalSession(
            write: { data in
                Task { @MainActor in
                    await relay.owner?.receiveInteractiveTerminalInput(data)
                }
            },
            resize: { size in Task { @MainActor in await relay.owner?.resize(size) } },
            suppressesPixelOnlyResizes: true
        )
        terminal = TerminalViewState(configSource: .none)
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(backend), resizeThrottleMilliseconds: 35)
        let owner = surfaceOwner
        terminal.makePlatformView = { owner.view }
        terminal.inputAccessoryItems = []
        relay.owner = self
        workingDirectoryObservation = terminal.$workingDirectory.sink { [weak relay] path in
            Task { @MainActor in
                relay?.owner?.receiveWorkingDirectory(path)
            }
        }
    }

    private func makeAuthenticationPrompt() -> SSHAuthenticationPrompt? {
        guard authenticationRequired, let host = hosts.host(authenticationHostID ?? descriptor.hostID) else {
            return nil
        }
        let staged = submissions[host.id]
        let identity = staged?.identityID.flatMap { hosts.identity($0) } ?? hosts.identity(for: host)
        let keyID = staged?.keyID ?? identity?.keyID
        return SSHAuthenticationPrompt(
            host: host, selectedIdentityID: identity?.id, username: username,
            selectedKeyID: keyID, failureMessage: connectionFailure,
            requiresPassphrase: keyID.flatMap { hosts.key($0) }?.requiresPassphraseEntry == true
                && staged?.passphrase == nil,
            mode: authenticationMode)
    }

    var hostKeyPrompt: SSHHostKeyPrompt? {
        guard let observation = pendingHostKey else { return nil }
        let count = pendingHostKeyHostID.flatMap { hosts.host($0) }.map { hosts.knownHosts(for: $0).count } ?? 0
        return SSHHostKeyPrompt(
            observation: observation, kind: count == 0 ? .firstUse : .additionalKey(trustedKeyCount: count))
    }

    private func preparation(for host: Host) throws -> SSHConnectionPreparation {
        var result = try hosts.prepareSSHConnection(for: host, submissions: submissions)
        for index in result.nodes.indices {
            if let key = temporaryKeys[result.nodes[index].host.id] { result.nodes[index].trustedKeys.insert(key) }
        }
        return result
    }

    func submitAuthentication(
        identityID: UUID?, username: String, password: String?, passphrase: String?, keyID: UUID?, save: Bool
    ) {
        guard var host = hosts.host(authenticationHostID ?? descriptor.hostID) else { return }
        let identity = identityID.flatMap { hosts.identity($0) }
        let name = (identity?.username ?? username).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if authenticationPrompt?.requiresPassphrase == true, var staged = submissions[host.id] {
            staged.passphrase = passphrase
            submissions[host.id] = staged
        } else {
            let chosenKey = identity?.keyID ?? keyID
            if save {
                do {
                    let value = identity ?? Identity(name: name, username: name, keyID: chosenKey)
                    try hosts.upsert(value, passwordUpdate: password.map(IdentityPasswordUpdate.replace) ?? .keep)
                    host.identityID = value.id
                    hosts.upsert(host)
                } catch {
                    connectionFailure = error.localizedDescription
                    authenticationPrompt = makeAuthenticationPrompt()
                    return
                }
            }
            submissions[host.id] = SSHAuthenticationSubmission(
                username: name, password: password, passphrase: passphrase,
                keyID: chosenKey, identityID: identity?.id)
        }
        authenticationRequired = false
        authenticationPrompt = nil

        journey.resume()
        connect()
    }

    func presentFind() {
        let wasOpen = isFindPresented
        isFindPresented = true
        if !wasOpen && !findQuery.isEmpty { _ = terminal.performBindingAction("search:\(findQuery)") }
    }

    func updateFindQuery(_ query: String) {
        findQuery = query
        _ = terminal.performBindingAction("search:\(query)")
    }

    func navigateFind(previous: Bool) {
        presentFind()
        guard !findQuery.isEmpty else { return }
        _ = terminal.performBindingAction(previous ? "navigate_search:previous" : "navigate_search:next")
    }

    func dismissFind() {
        _ = terminal.performBindingAction("end_search")
        isFindPresented = false
        terminal.requestFocus()
    }

    func insertHistory(_ command: String) {
        guard connected else { return }
        _ = terminal.paste(text: command)
        terminal.requestFocus()
    }

    func generateCommand(using generator: any CommandGenerating) {
        if commandGeneratorTask != nil {
            cancelCommandGeneration()
            return
        }
        guard descriptor.kind == .ssh, canGenerateFromCurrentDraft else {
            showCommandGenerationFailure(
                String(
                    localized:
                        "Command Generator requires a supported shell prompt with Shell Integration enabled."
                )
            )
            return
        }
        guard let workingDirectory, !workingDirectory.isEmpty, let integratedShell else {
            showCommandGenerationFailure(
                String(localized: "The focused shell has not reported its current directory.")
            )
            return
        }

        commandGeneratorDismissTask?.cancel()
        commandGenerationSequence &+= 1
        let sequence = commandGenerationSequence
        let connectionGeneration = generation
        let revision = commandGeneratorRevision
        commandGeneratorState = .readingDraft
        commandGeneratorTask = Task { [weak self, generator] in
            do {
                guard let self else { return }
                let draft = try await requestCurrentDraft()
                try Task.checkCancellation()
                guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MobileCommandGenerationError.emptyDraft
                }
                guard
                    commandGenerationSnapshotIsCurrent(
                        sequence: sequence,
                        connectionGeneration: connectionGeneration,
                        revision: revision,
                        shell: integratedShell,
                        workingDirectory: workingDirectory
                    )
                else { throw CancellationError() }

                commandGeneratorState = .generating
                let context = CommandGeneratorContext(
                    draft: draft,
                    shell: integratedShell,
                    cwd: workingDirectory,
                    remoteSystemInfo: terminalSettings.preferences.shellIntegration
                        ? remoteSystemInfo : nil
                )
                let command = try await mobileCommandGenerationWithTimeout {
                    try await generator.generate(context)
                }
                try Task.checkCancellation()
                guard
                    commandGenerationSnapshotIsCurrent(
                        sequence: sequence,
                        connectionGeneration: connectionGeneration,
                        revision: revision,
                        shell: integratedShell,
                        workingDirectory: workingDirectory
                    )
                else { throw CancellationError() }

                await replaceCurrentDraft(with: command)
                finishCommandGeneration(
                    sequence: sequence,
                    state: .inserted(targetCount: 1),
                    dismissAfter: .seconds(2)
                )
            } catch is CancellationError {
                self?.finishCancelledCommandGeneration(sequence: sequence)
            } catch {
                self?.finishCommandGeneration(
                    sequence: sequence,
                    state: .failed(error.localizedDescription),
                    dismissAfter: .seconds(3)
                )
            }
        }
    }

    func cancelCommandGeneration() {
        guard commandGeneratorTask != nil || pendingDraftRequest != nil else { return }
        commandGenerationSequence &+= 1
        commandGeneratorTask?.cancel()
        commandGeneratorTask = nil
        commandGeneratorDismissTask?.cancel()
        commandGeneratorDismissTask = nil
        if let request = pendingDraftRequest {
            failDraftRequest(id: request.id, with: CancellationError())
        }
        commandGeneratorState = .idle
    }

    func receiveWorkingDirectory(_ path: String?) {
        let path = path?.isEmpty == false ? path : nil
        guard workingDirectory != path else { return }
        workingDirectory = path
        cancelPendingUpload()
        invalidateCommandGeneration()
    }

    private var canGenerateFromCurrentDraft: Bool {
        connected && shellIntegrationAvailable && isShellPromptReady
            && Self.supportedGeneratorShells.contains(integratedShell ?? "")
    }

    func receiveInteractiveTerminalInput(_ data: Data) async {
        invalidateCommandGeneration()
        await writeSSHDirectly(data)
    }

    private func writeSSHDirectly(_ data: Data) async {
        guard let ssh else { return }
        await connectionServices.writeSSH(ssh, data)
    }

    private func requestCurrentDraft() async throws -> String {
        guard canGenerateFromCurrentDraft else { throw MobileCommandDraftError.unavailable }
        guard pendingDraftRequest == nil else { throw MobileCommandDraftError.alreadyPending }
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, any Error>) in
                pendingDraftRequest = MobilePendingDraftRequest(
                    id: requestID,
                    continuation: continuation
                )
                Task { [weak self] in
                    await self?.writeSSHDirectly(Self.commandGeneratorDraftRequest)
                }
                draftRequestTimeoutTask?.cancel()
                draftRequestTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    self?.failDraftRequest(
                        id: requestID,
                        with: MobileCommandDraftError.timedOut
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.failDraftRequest(id: requestID, with: CancellationError())
            }
        }
    }

    private func replaceCurrentDraft(with command: String) async {
        var data = Self.commandGeneratorDraftClear
        data.append(Self.bracketedPasteStart)
        data.append(Data(command.utf8))
        data.append(Self.bracketedPasteEnd)
        await writeSSHDirectly(data)
        terminal.requestFocus()
    }

    private func failDraftRequest(id: UUID, with error: any Error) {
        guard pendingDraftRequest?.id == id, let request = pendingDraftRequest else { return }
        pendingDraftRequest = nil
        draftRequestTimeoutTask?.cancel()
        draftRequestTimeoutTask = nil
        request.continuation.resume(throwing: error)
    }

    private func completeDraftRequest(with draft: String) {
        guard let request = pendingDraftRequest else { return }
        pendingDraftRequest = nil
        draftRequestTimeoutTask?.cancel()
        draftRequestTimeoutTask = nil
        request.continuation.resume(returning: draft)
    }

    private func commandGenerationSnapshotIsCurrent(
        sequence: UInt64,
        connectionGeneration: UUID,
        revision: UInt64,
        shell: String,
        workingDirectory: String
    ) -> Bool {
        commandGenerationSequence == sequence
            && generation == connectionGeneration
            && commandGeneratorRevision == revision
            && integratedShell == shell
            && self.workingDirectory == workingDirectory
            && canGenerateFromCurrentDraft
    }

    private func invalidateCommandGeneration() {
        commandGeneratorRevision &+= 1
        if commandGeneratorTask != nil { cancelCommandGeneration() }
    }

    private func resetCommandGeneratorShellState() {
        cancelCommandGeneration()
        integratedShell = nil
        remoteSystemInfo = nil
        isShellPromptReady = false
        shellIntegrationAvailable = false
        workingDirectory = nil
        if let request = pendingDraftRequest {
            failDraftRequest(id: request.id, with: MobileCommandDraftError.unavailable)
        }
        commandGeneratorRevision &+= 1
    }

    private func commandGenerationDidFinish(sequence: UInt64) -> Bool {
        guard commandGenerationSequence == sequence else { return false }
        commandGeneratorTask = nil
        return true
    }

    private func finishCancelledCommandGeneration(sequence: UInt64) {
        guard commandGenerationDidFinish(sequence: sequence) else { return }
        commandGeneratorState = .idle
    }

    private func finishCommandGeneration(
        sequence: UInt64,
        state: CommandGeneratorState,
        dismissAfter: Duration
    ) {
        guard commandGenerationDidFinish(sequence: sequence) else { return }
        commandGeneratorState = state
        scheduleCommandGenerationDismiss(sequence: sequence, after: dismissAfter)
    }

    private func showCommandGenerationFailure(_ message: String) {
        commandGenerationSequence &+= 1
        commandGeneratorTask?.cancel()
        commandGeneratorTask = nil
        commandGeneratorDismissTask?.cancel()
        commandGeneratorState = .failed(message)
        scheduleCommandGenerationDismiss(
            sequence: commandGenerationSequence,
            after: .seconds(3)
        )
    }

    private func scheduleCommandGenerationDismiss(sequence: UInt64, after delay: Duration) {
        commandGeneratorDismissTask?.cancel()
        commandGeneratorDismissTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self?.commandGenerationSequence == sequence else { return }
            self?.commandGeneratorState = .idle
            self?.commandGeneratorDismissTask = nil
        }
    }

    func receiveShellEvent(_ event: SSHShellIntegrationEvent) {
        guard terminalSettings.preferences.shellIntegration else {
            activeHistoryID = nil
            resetCommandGeneratorShellState()
            return
        }
        switch event {
        case .available(let shell, let systemInfo, _):
            integratedShell = shell
            remoteSystemInfo = systemInfo
            isShellPromptReady = false
            shellIntegrationAvailable = true
            invalidateCommandGeneration()
            hosts.recordRemoteSystemInfo(systemInfo, for: descriptor.hostID)
        case .systemInfo(let systemInfo):
            remoteSystemInfo = systemInfo
            invalidateCommandGeneration()
            hosts.recordRemoteSystemInfo(systemInfo, for: descriptor.hostID)
        case .homeResolutionUnavailable:
            break
        case .promptReady:
            isShellPromptReady = true
            invalidateCommandGeneration()
        case .commandStarted(let command):
            guard shellIntegrationAvailable else { return }
            isShellPromptReady = false
            invalidateCommandGeneration()
            activeHistoryID = commandHistory.record(command, for: descriptor.hostID)?.id
        case .commandFinished(let status, let duration):
            guard let id = activeHistoryID else { return }
            commandHistory.recordCompletion(for: id, hostID: descriptor.hostID, exitStatus: status, duration: duration)
            activeHistoryID = nil
        case .draft(let draft):
            completeDraftRequest(with: draft)
        }
    }

    func connect() {
        guard !busy, !connected else { return }
        cancelPendingUpload()
        let reconnecting = reconnect.isRecovering
        let token = UUID()
        generation = token
        activeHistoryID = nil
        resetCommandGeneratorShellState()
        busy = true
        connectionFailure = nil
        status = String(localized: reconnecting ? "Reconnecting" : "Connecting")
        guard let host = hosts.host(descriptor.hostID) else {
            let message = String(localized: "The host is no longer available.")
            reconnect.stopRecovery()
            connectionFailure = message
            status = String(localized: "Disconnected")
            busy = false
            journey.fail(message)
            return
        }
        let route = hosts.route(for: host)
        journey.begin(
            host: host, route: route,
            purpose: descriptor.kind == .ssh ? .sshSession : .sftpSession,
            username: hosts.identity(for: host)?.username,
            mode: reconnecting ? .reconnection : .connection)
        attempt = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { busy = false } }
            guard generation == token, !Task.isCancelled else { return }
            do {
                // Validate each hop in order so credentials and trust prompts name the actual endpoint.
                for endpoint in route {
                    guard generation == token, !Task.isCancelled else { return }
                    let preparation = try preparation(for: endpoint)
                    let discovery = try await preparation.resolve(discoveryOnly: true)
                    guard generation == token, !Task.isCancelled else { return }
                    journey.receive(.connecting(endpoint.id))
                    let observation = try await connectionServices.discoverHostKey(
                        endpoint.id, endpoint.host, endpoint.port, discovery.proxy, discovery.jumps)
                    guard generation == token, !Task.isCancelled else { return }
                    let trusted = hosts.knownHosts(for: endpoint)
                    if !trusted.contains(where: { $0.identity == observation.identity })
                        && temporaryKeys[endpoint.id] != observation.identity
                    {
                        if trusted.contains(where: { $0.algorithm == observation.algorithm }) {
                            hosts.markKnownHostMismatched(hostname: endpoint.host, port: endpoint.port)
                            throw TermindSSHError.hostKeyChanged(
                                expected: trusted.map(\.fingerprint), received: observation.fingerprint)
                        }
                        pendingHostKeyHostID = endpoint.id
                        pendingHostKey = observation
                        reconnect.pauseForUserInteraction()
                        journey.waitForHostKey(at: endpoint.id, fingerprint: observation.fingerprint)
                        status = String(localized: "Waiting for approval")
                        return
                    }
                }
                let preparation = try preparation(for: host)
                let config = try await preparation.resolve()
                guard generation == token, !Task.isCancelled else { return }

                if descriptor.kind == .ssh {
                    let backend = backend
                    let session = connectionServices.makeSSHSession(
                        { backend.receive($0) },
                        { [weak self] result in
                            Task { @MainActor in
                                guard let self, self.generation == token else { return }
                                self.handleRemoteExit(result)
                            }
                        },
                        { [weak self] event in
                            Task { @MainActor in
                                guard let self, self.generation == token else { return }
                                self.receiveShellEvent(event)
                                self.didChangeState?()
                            }
                        })
                    ssh = session
                    try await connectionServices.connectSSH(
                        session,
                        config,
                        terminalSettings.preferences.shellIntegration,
                        UInt16(clamping: viewport.columns),
                        UInt16(clamping: viewport.rows),
                        { [weak self] event in
                            Task { @MainActor in
                                guard let self, self.generation == token else { return }
                                self.journey.receive(event)
                            }
                        }
                    )
                } else {
                    let client = try await connectionServices.connectSFTP(
                        config, nil,
                        { [weak self] message in
                            Task { @MainActor in
                                guard let self, self.generation == token else { return }
                                self.handleConnectionFailure(message)
                            }
                        })
                    guard generation == token, !Task.isCancelled else {
                        await client.disconnect()
                        return
                    }
                    sftp = client
                    if !reconnecting {
                        path =
                            host.sftpSessionInitialPath.isEmpty
                            ? try await client.homeDirectory() : host.sftpSessionInitialPath
                    }
                    files = try await client.listDirectory(at: path)
                }
                guard generation == token, !Task.isCancelled else { return }
                transferConfiguration = config
                submissions.removeAll()
                let wasReconnecting = reconnect.markConnected()
                connected = true
                status = String(localized: "Connected")
                journey.succeed()
                if wasReconnecting, descriptor.kind == .ssh {
                    appendTerminalNotice(String(localized: "Reconnected; a new remote shell has started."))
                }
                if descriptor.kind == .ssh, let session = ssh,
                    let command = consumePendingInitialCommand()
                {
                    await connectionServices.writeSSH(session, Data((command + "\r").utf8))
                }
            } catch {
                guard generation == token else { return }
                connectionFailure = error.localizedDescription
                var requiresUserInteraction = false
                var preventsAutomaticReconnect = false
                if let sshError = error as? TermindSSHError {
                    switch sshError {
                    case .missingCredential, .missingUsername, .keyPassphraseRequired, .authenticationFailed:
                        authenticationRequired = true
                    default: authenticationRequired = sshError.shouldRequestAuthentication
                    }
                    if authenticationRequired {
                        requiresUserInteraction = true
                        reconnect.pauseForUserInteraction()
                        authenticationMode =
                            sshError.isServerAuthenticationChallenge ? .serverChallenge : .localIdentity
                        authenticationHostID = sshError.routeHostID ?? descriptor.hostID
                        if let endpoint = hosts.host(authenticationHostID ?? descriptor.hostID) {
                            username =
                                submissions[endpoint.id]?.username ?? hosts.identity(for: endpoint)?.username ?? ""
                        }
                        authenticationPrompt = makeAuthenticationPrompt()
                        if authenticationPrompt?.requiresPassphrase == true {
                            journey.waitForLocalPassphrase(
                                at: authenticationHostID ?? descriptor.hostID, failure: error.localizedDescription)
                        } else if sshError.isServerAuthenticationChallenge {
                            journey.waitForAuthentication(
                                at: authenticationHostID ?? descriptor.hostID, failure: error.localizedDescription)
                        } else {
                            journey.waitForLocalIdentity(
                                at: authenticationHostID ?? descriptor.hostID, failure: error.localizedDescription)
                        }

                    }
                    if sshError.isHostKeyChanged || sshError.shouldRequestHostKey {
                        preventsAutomaticReconnect = true
                    }
                    switch sshError {
                    case .untrustedHost, .mismatchedHostKey:
                        preventsAutomaticReconnect = true
                    default:
                        break
                    }
                }
                if !requiresUserInteraction {
                    if (reconnect.hasConnectedOnce || reconnecting) && !preventsAutomaticReconnect {
                        scheduleReconnect(after: error.localizedDescription)
                    } else {
                        reconnect.stopRecovery()
                        journey.fail(error.localizedDescription)
                        status = String(localized: "Disconnected")
                    }
                }
                await ssh?.disconnect()
                await sftp?.disconnect()
                ssh = nil
                sftp = nil
            }
        }
    }

    /// Consumes the launch-only command before it is written. Reconnects and
    /// restored descriptors therefore cannot replay a script.
    func consumePendingInitialCommand() -> String? {
        defer { pendingInitialCommand = nil }
        return pendingInitialCommand
    }

    func retryReconnectNow() {
        reconnect.retryNow()
    }

    func stopReconnecting() {
        guard let reconnectState = reconnect.stopReconnecting() else { return }
        cancelPendingUpload()
        resetCommandGeneratorShellState()
        connectionResumeIntent = .none
        generation = UUID()
        attempt?.cancel()
        attempt = nil
        let oldSSH = ssh
        let oldSFTP = sftp
        ssh = nil
        sftp = nil
        busy = false
        connected = false
        transferConfiguration = nil
        status = String(localized: "Disconnected")
        connectionFailure = reconnectState.lastError
        journey.fail(reconnectState.lastError)
        Task {
            await oldSSH?.disconnect()
            await oldSFTP?.disconnect()
        }
    }

    func activateWhenOpened() {
        guard connectionResumeIntent == .whenOpened else { return }
        connectionResumeIntent = .none
        connect()
    }

    func suspendForBackgroundExpiration() {
        guard connectionResumeIntent != .foreground, hasActiveConnectionFlow else { return }
        cancelPendingUpload()
        resetCommandGeneratorShellState()
        let reconnecting = reconnect.hasConnectedOnce
        connectionResumeIntent = .foreground
        generation = UUID()
        attempt?.cancel()
        attempt = nil
        let oldSSH = ssh
        let oldSFTP = sftp
        ssh = nil
        sftp = nil
        busy = false
        connected = false
        transferConfiguration = nil
        activeHistoryID = nil
        authenticationRequired = false
        authenticationPrompt = nil
        pendingHostKeyHostID = nil
        pendingHostKey = nil
        temporaryKeys.removeAll()
        submissions.removeAll()
        connectionFailure = nil
        operationError = nil
        reconnect.suspendForForegroundResume(reconnecting: reconnecting)
        status = String(localized: reconnecting ? "Reconnecting" : "Connecting")
        presentConnectionJourney(mode: reconnecting ? .reconnection : .connection)
        Task {
            await oldSSH?.disconnect()
            await oldSFTP?.disconnect()
        }
    }

    func resumeAfterBackground() {
        guard connectionResumeIntent == .foreground else { return }
        connectionResumeIntent = .none
        connect()
    }

    private func handleRemoteExit(_ result: Result<Int32, TermindSSHError>) {
        cancelPendingUpload()
        resetCommandGeneratorShellState()
        generation = UUID()
        attempt?.cancel()
        attempt = nil
        busy = false
        connected = false
        ssh = nil
        transferConfiguration = nil
        switch result {
        case .success:
            connectionResumeIntent = .none
            reconnect.reset()
            status = String(localized: "Disconnected")
        case .failure(let failure):
            handleConnectionFailure(failure.localizedDescription)
        }
    }

    private func handleConnectionFailure(_ message: String) {
        guard reconnect.hasConnectedOnce else { return }
        scheduleReconnect(after: message)
    }

    private func scheduleReconnect(after message: String) {
        cancelPendingUpload()
        resetCommandGeneratorShellState()
        let announcesLoss = reconnect.schedule(after: message) { [weak self] in self?.connect() }
        generation = UUID()
        attempt?.cancel()
        attempt = nil
        let oldSSH = ssh
        let oldSFTP = sftp
        ssh = nil
        sftp = nil
        busy = false
        connected = false
        transferConfiguration = nil
        status = String(localized: "Reconnecting")
        if announcesLoss, descriptor.kind == .ssh {
            appendTerminalNotice(String(localized: "Connection lost; reconnecting…"))
        }
        if let host = hosts.host(descriptor.hostID) {
            journey.begin(
                host: host, route: hosts.route(for: host),
                purpose: descriptor.kind == .ssh ? .sshSession : .sftpSession,
                username: hosts.identity(for: host)?.username, mode: .reconnection)
        }
        Task {
            await oldSSH?.disconnect()
            await oldSFTP?.disconnect()
        }
    }

    private func appendTerminalNotice(_ message: String) {
        backend.receive(Data("\r\n\u{001B}[2m[Termind] \(message)\u{001B}[0m\r\n".utf8))
    }

    func trustHostKey(remember: Bool = true) {
        guard let observation = pendingHostKey else { return }
        if remember {
            hosts.trust(
                KnownHostEntry(
                    hostname: observation.hostname, port: observation.port,
                    algorithm: observation.algorithm, fingerprint: observation.fingerprint, addedAt: .now))
        } else {
            temporaryKeys[pendingHostKeyHostID ?? descriptor.hostID] = observation.identity
        }
        journey.resume()
        pendingHostKey = nil
        connect()
    }

    func disconnect() {
        cancelPendingUpload()
        resetCommandGeneratorShellState()
        connectionResumeIntent = .none
        journey.hide()
        reconnect.reset()
        connectionFailure = nil
        operationError = nil
        pendingHostKey = nil
        authenticationRequired = false
        authenticationPrompt = nil
        temporaryKeys.removeAll()
        submissions.removeAll()

        activeHistoryID = nil
        generation = UUID()
        attempt?.cancel()
        attempt = nil
        transferConfiguration = nil
        let oldSSH = ssh
        let oldSFTP = sftp
        ssh = nil
        sftp = nil
        Task {
            await oldSSH?.disconnect()
            await oldSFTP?.disconnect()
        }
        busy = false
        connected = false

        submissions.removeAll()
        authenticationRequired = false
        authenticationPrompt = nil
        pendingHostKey = nil
        status = String(localized: "Disconnected")
    }

    private var hasActiveConnectionFlow: Bool {
        if connected || busy || reconnect.isRecovering || authenticationRequired || pendingHostKey != nil {
            return true
        }
        switch journey.phase {
        case .connecting, .waiting, .succeeded: return true
        case .hidden, .failed: return false
        }
    }

    private func presentConnectionJourney(mode: ConnectionJourney.Mode) {
        guard let host = hosts.host(descriptor.hostID) else {
            journey.fail(String(localized: "The host is no longer available."))
            return
        }
        journey.begin(
            host: host, route: hosts.route(for: host),
            purpose: descriptor.kind == .ssh ? .sshSession : .sftpSession,
            username: hosts.identity(for: host)?.username, mode: mode)
    }

    func openDirectory(_ directory: String) async {
        guard let sftp else { return }
        let connection = generation
        let request = UUID()
        directoryRequest = request
        do {
            let entries = try await sftp.listDirectory(at: directory)
            guard generation == connection, directoryRequest == request else { return }
            if path != directory { cancelPendingUpload() }
            path = directory
            files = entries.sorted { ($0.isDirectory ? 0 : 1, $0.name) < ($1.isDirectory ? 0 : 1, $1.name) }
        } catch {
            guard generation == connection, directoryRequest == request else { return }
            if handleSFTPConnectionError(error, connection: connection) { return }
            operationError = error.localizedDescription
        }
    }

    func rename(_ file: RemoteFile, to name: String) async throws {
        guard validName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        guard let sftp else { throw TermindSSHError.disconnected }
        let connection = generation
        do {
            try await sftp.rename(
                from: file.path, to: RemotePath.join(RemotePath.parent(of: file.path), name), overwrite: false)
        } catch {
            if handleSFTPConnectionError(error, connection: connection) { return }
            throw error
        }
        guard connection == generation else { throw CancellationError() }
        await openDirectory(path)
    }

    func setPermissions(_ file: RemoteFile, mode: UInt32) async throws {
        guard let sftp else { throw TermindSSHError.disconnected }
        let connection = generation
        do {
            try await sftp.setPermissions(at: file.path, to: mode & 0o7777)
        } catch {
            if handleSFTPConnectionError(error, connection: connection) { return }
            throw error
        }
        guard connection == generation else { throw CancellationError() }
        await openDirectory(path)
    }

    func createDirectory(_ name: String) async {
        guard let sftp, validName(name) else { return }
        let connection = generation
        do {
            try await sftp.createDirectory(at: RemotePath.join(path, name))
            await openDirectory(path)
        } catch {
            if !handleSFTPConnectionError(error, connection: connection) {
                operationError = error.localizedDescription
            }
        }
    }

    func delete(_ file: RemoteFile) async {
        guard let sftp else { return }
        let connection = generation
        do {
            if file.isDirectory {
                try await sftp.removeDirectory(at: file.path)
            } else {
                try await sftp.removeFile(at: file.path)
            }
            await openDirectory(path)
        } catch {
            if !handleSFTPConnectionError(error, connection: connection) {
                operationError = error.localizedDescription
            }
        }
    }

    @discardableResult
    func prepareUpload(_ urls: [URL]) -> Bool {
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { return false }
        guard transfers != nil, let configuration = transferConfiguration,
            let destination = uploadDestination
        else {
            showUploadNotice(
                .rejected(
                    uploadTargetProblem
                        ?? String(localized: "The upload destination is unavailable.")
                )
            )
            return false
        }

        cancelPendingUpload()
        let connectionGeneration = generation
        uploadNotice = .preparing(destination)
        uploadPreparationTask = Task { [weak self] in
            guard let self else { return }
            var client: (any SFTPClientProtocol)?
            var ownsClient = false
            do {
                if descriptor.kind == .sftp {
                    guard let sftp else { throw SFTPError.notConnected }
                    client = sftp
                } else {
                    client = try await connectionServices.connectSFTP(
                        configuration,
                        nil,
                        nil
                    )
                    ownsClient = true
                }
                try Task.checkCancellation()
                guard generation == connectionGeneration, uploadDestination == destination,
                    let client
                else { throw CancellationError() }
                let batch = try await SFTPLocalUploadPlanner.prepare(
                    urls,
                    destination: destination,
                    client: client
                )
                try Task.checkCancellation()
                guard generation == connectionGeneration, uploadDestination == destination else {
                    throw CancellationError()
                }
                guard !batch.isEmpty else {
                    throw SFTPError.localFile(String(localized: "No uploadable files were found."))
                }
                pendingUpload = MobilePendingUpload(
                    batch: batch,
                    destination: destination,
                    client: client,
                    ownsClient: ownsClient,
                    configuration: configuration,
                    connectionGeneration: connectionGeneration
                )
                uploadPreparationTask = nil
                if batch.conflictCount > 0 {
                    uploadNotice = nil
                } else {
                    enqueuePendingUpload(.replace)
                }
            } catch is CancellationError {
                if ownsClient { await client?.disconnect() }
                uploadNotice = nil
                uploadPreparationTask = nil
            } catch {
                if ownsClient { await client?.disconnect() }
                uploadNotice = nil
                operationError = error.localizedDescription
                uploadPreparationTask = nil
            }
        }
        return true
    }

    func enqueuePendingUpload(_ policy: TransferConflictPolicy) {
        guard let pendingUpload, let transfers else { return }
        self.pendingUpload = nil
        uploadEnqueueTask?.cancel()
        uploadEnqueueTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await SFTPLocalUploadPlanner.enqueue(
                    pendingUpload.batch,
                    policy: policy,
                    hostID: descriptor.hostID,
                    connection: .saved(pendingUpload.configuration),
                    client: pendingUpload.client,
                    coordinator: transfers
                ) { [weak self] state in
                    guard state == .completed else { return }
                    Task { @MainActor in
                        guard let self,
                            self.descriptor.kind == .sftp,
                            self.generation == pendingUpload.connectionGeneration
                        else { return }
                        await self.openDirectory(self.path)
                    }
                }
                if pendingUpload.ownsClient { await pendingUpload.client.disconnect() }
                guard generation == pendingUpload.connectionGeneration else { return }
                if result.changedRemoteDirectories, descriptor.kind == .sftp {
                    await openDirectory(path)
                }
                showUploadNotice(
                    .queued(pendingUpload.batch.rootCount, pendingUpload.destination)
                )
                uploadEnqueueTask = nil
            } catch is CancellationError {
                if pendingUpload.ownsClient { await pendingUpload.client.disconnect() }
                uploadNotice = nil
                uploadEnqueueTask = nil
            } catch {
                if pendingUpload.ownsClient { await pendingUpload.client.disconnect() }
                uploadNotice = nil
                operationError = error.localizedDescription
                uploadEnqueueTask = nil
            }
        }
    }

    func cancelPendingUpload() {
        uploadPreparationTask?.cancel()
        uploadPreparationTask = nil
        uploadEnqueueTask?.cancel()
        uploadEnqueueTask = nil
        uploadNoticeTask?.cancel()
        uploadNoticeTask = nil
        uploadNotice = nil
        guard let pendingUpload else { return }
        self.pendingUpload = nil
        if pendingUpload.ownsClient {
            Task { await pendingUpload.client.disconnect() }
        }
    }

    private func showUploadNotice(_ notice: MobileUploadNotice) {
        uploadNoticeTask?.cancel()
        uploadNotice = notice
        uploadNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, self?.uploadNotice == notice else { return }
            self?.uploadNotice = nil
            self?.uploadNoticeTask = nil
        }
    }

    func download(_ file: RemoteFile) {
        guard let transfers, let configuration = transferConfiguration, connected, !file.isDirectory else { return }
        do {
            guard validName(file.name) else { throw CocoaError(.fileWriteInvalidFileName) }
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "TermindDownloads", directoryHint: .isDirectory
            )
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            transfers.enqueue(
                direction: .download, batchID: UUID(), localURL: directory.appending(path: file.name),
                remotePath: file.path, byteCount: file.size, hostID: descriptor.hostID,
                configuration: configuration, scopedRoot: directory, overwrite: false)
        } catch { operationError = error.localizedDescription }
    }

    private func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static let supportedGeneratorShells: Set<String> = ["bash", "zsh", "fish"]
    private static let commandGeneratorDraftRequest = Data("\u{1B}[777;1~".utf8)
    private static let commandGeneratorDraftClear = Data("\u{1B}[777;2~".utf8)
    private static let bracketedPasteStart = Data("\u{1B}[200~".utf8)
    private static let bracketedPasteEnd = Data("\u{1B}[201~".utf8)

    private func handleSFTPConnectionError(_ error: any Error, connection: UUID) -> Bool {
        guard generation == connection, reconnect.hasConnectedOnce, let sftpError = error as? SFTPError else {
            return false
        }
        switch sftpError {
        case .connectionLost(let message):
            handleConnectionFailure(message)
            return true
        case .notConnected:
            handleConnectionFailure(sftpError.localizedDescription)
            return true
        case .cancelled, .localFile, .operation:
            return false
        }
    }

    private func resize(_ size: InMemoryTerminalViewport) async {
        viewport = size
        await ssh?.resize(
            columns: UInt16(clamping: size.columns), rows: UInt16(clamping: size.rows),
            widthPixels: UInt32(clamping: size.widthPixels), heightPixels: UInt32(clamping: size.heightPixels))
    }
}

private nonisolated enum MobileCommandDraftError: LocalizedError {
    case unavailable
    case alreadyPending
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(
                localized:
                    "Command Generator requires a supported shell prompt with Shell Integration enabled."
            )
        case .alreadyPending:
            String(localized: "Command Generator is already reading the current input.")
        case .timedOut:
            String(localized: "The remote shell did not return its current input.")
        }
    }
}

private nonisolated enum MobileCommandGenerationError: LocalizedError {
    case emptyDraft

    var errorDescription: String? {
        String(localized: "Type something at the shell prompt before generating a command.")
    }
}

private nonisolated func mobileCommandGenerationWithTimeout(
    _ operation: @escaping @Sendable () async throws -> String
) async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(30))
            throw CommandGeneratorError.timedOut
        }
        guard let result = try await group.next() else {
            throw CommandGeneratorError.invalidResponse
        }
        group.cancelAll()
        return result
    }
}

@MainActor
@Observable
final class MobileWorkspaceReconnectState {
    private let controller: SessionReconnectController
    private(set) var hasConnectedOnce = false
    private(set) var isRecovering = false

    var state: ReconnectState? { controller.state }

    init(controller: SessionReconnectController = SessionReconnectController()) {
        self.controller = controller
    }

    @discardableResult
    func markConnected() -> Bool {
        let wasRecovering = isRecovering
        let initialConnection = !hasConnectedOnce
        hasConnectedOnce = true
        isRecovering = false
        controller.markConnected(initial: initialConnection)
        return wasRecovering
    }

    @discardableResult
    func schedule(after message: String, retry: @escaping SessionReconnectController.RetryAction) -> Bool {
        guard hasConnectedOnce else { return false }
        let announcesLoss = !isRecovering
        isRecovering = true
        controller.schedule(after: message, retry: retry)
        return announcesLoss
    }

    func pauseForUserInteraction() {
        controller.pauseForUserInteraction()
    }

    func retryNow() {
        controller.retryNow()
    }

    func stopReconnecting() -> ReconnectState? {
        guard let state else { return nil }
        controller.stop()
        isRecovering = false
        return state
    }

    func stopRecovery() {
        controller.stop()
        isRecovering = false
    }

    func suspendForForegroundResume(reconnecting: Bool) {
        controller.stop()
        isRecovering = reconnecting && hasConnectedOnce
    }

    func reset() {
        controller.stop()
        hasConnectedOnce = false
        isRecovering = false
    }
}

@MainActor
private final class MobileTerminalRelay {
    weak var owner: MobileWorkspace?
}
