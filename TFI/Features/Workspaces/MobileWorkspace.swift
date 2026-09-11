import Combine
import Foundation
import GhosttyTerminal
import Observation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation
import TermindRemoteInfrastructure

import struct TermindDomain.Host

private enum MobileWorkspaceConnectionResumeIntent: Equatable {
    case none
    case whenOpened
    case foreground
}

private nonisolated enum MobileSSHSessionEvent: Sendable {
    case exit(Result<Int32, TermindSSHError>)
    case shellIntegration(SSHShellIntegrationEvent)
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
    @ObservationIgnored private(set) var activitySession: WorkspaceActivityAttributes.Session
    @ObservationIgnored var didChangeState: ((WorkspaceActivityAttributes.Session) -> Void)?
    @ObservationIgnored var didRequestClose: ((ID) -> Void)?
    private(set) var status = String(localized: "Disconnected")
    private(set) var connected = false {
        didSet {
            guard activitySession.connected != connected else { return }
            activitySession.connected = connected
            didChangeState?(activitySession)
        }
    }
    private(set) var busy = false
    var reconnectState: ReconnectState? { connection.reconnectState }
    var journey: ConnectionJourney { connection.journey }
    var operationError: String?
    private var connectionFailure: String?
    private(set) var authenticationPrompt: SSHAuthenticationPrompt?
    private var authenticationMode = SSHAuthenticationPrompt.Mode.localIdentity
    var authenticationRequired = false
    var username = ""
    private var authenticationHostID: UUID?
    private var temporaryKeys: [UUID: SSHHostKeyIdentity] {
        get { connection.temporaryHostKeys }
        set { connection.temporaryHostKeys = newValue }
    }
    private var submissions: [UUID: SSHAuthenticationSubmission] = [:]
    let sftpSession = MobileSFTPSessionModel()
    let transfers: SFTPTransferCoordinator?
    private var transferConfiguration: SSHConnectionConfiguration?
    private(set) var uploadNotice: WorkspaceUploadNotice?
    private var pendingUpload: MobilePendingUpload?
    private var uploadPreparationTask: Task<Void, Never>?
    private var uploadEnqueueTask: Task<Void, Never>?
    private var uploadNoticeTask: Task<Void, Never>?
    let terminalSettings: TerminalSettingsModel
    let commandHistory: CommandHistoryModel
    @ObservationIgnored lazy var find = TerminalFindController(
        perform: { [weak self] in _ = self?.terminal.performBindingAction($0) },
        focus: { [weak self] in self?.terminal.requestFocus() }
    )
    private var activeHistoryID: UUID?
    private var shellIntegrationAvailable = false
    private(set) var pendingInitialCommand: String?
    private(set) var workingDirectory: String?
    var commandGeneratorState: CommandGeneratorState { commandGeneration.state }
    private var integratedShell: String?
    private var remoteSystemInfo: RemoteSystemInfo?
    private var isShellPromptReady = false
    private var commandGeneratorRevision: UInt64 = 0
    private let commandGeneration = CommandGenerationCoordinator()
    private let commandDraft = TerminalCommandDraftController()
    private var workingDirectoryObservation: AnyCancellable?
    private let surfaceOwner = MobileTerminalSurface()
    let terminal: TerminalViewState
    private let backend: InMemoryTerminalSession
    private var ssh: SSHSessionActor?
    private var sftp: (any SFTPClientProtocol)?
    private var sshEventContinuation: AsyncStream<MobileSSHSessionEvent>.Continuation?
    private var sshEventTask: Task<Void, Never>?
    private var attempt: Task<Void, Never>?
    private var generation = UUID()
    private let hosts: any RemoteSessionHostStore
    private let connectionServices: MobileWorkspaceConnectionServices
    private let connection: RemoteSessionConnectionController
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
            return sftpSession.path
        }
    }

    var uploadTargetProblem: String? {
        switch descriptor.kind {
        case .ssh:
            return TerminalUploadAvailability.problem(
                isConnected: connected,
                hasTransferConfiguration: transferConfiguration != nil,
                isWorkingDirectoryPending: workingDirectory == nil,
                workingDirectory: workingDirectory
            )
        case .sftp:
            guard connected, transferConfiguration != nil, sftp != nil else {
                return String(localized: "The SFTP session is not connected.")
            }
            return nil
        }
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
        activitySession = WorkspaceActivityAttributes.Session(
            id: descriptor.id, title: descriptor.title, kind: descriptor.kind.rawValue,
            connected: false,
            iconAsset: LinuxDistributionIconCatalog.entry(
                for: hosts.host(descriptor.hostID)?.detectedDistribution)?.asset)
        pendingInitialCommand = initialCommand
        self.connectionServices = connectionServices
        connection = RemoteSessionConnectionController(reconnect: reconnectController)
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

    var hostKeyPrompt: SSHHostKeyPrompt? { connection.pendingHostKey }

    private func preparation(for host: Host) throws -> SSHConnectionPreparation {
        try hosts.prepareSSHConnection(
            for: host,
            submissions: submissions,
            temporaryHostKeys: temporaryKeys
        )
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

    func insertHistory(_ command: String) {
        guard connected else { return }
        _ = terminal.paste(text: command)
        terminal.requestFocus()
    }

    func generateCommand(using generator: any CommandGenerating) {
        if commandGeneration.isRunning {
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

        let connectionGeneration = generation
        let revision = commandGeneratorRevision
        let includesSystemInfo = terminalSettings.preferences.shellIntegration
        commandGeneration.start(
            targetCount: 1,
            readContext: { [weak self] in
                guard let self else { throw CancellationError() }
                let draft = try await requestCurrentDraft()
                return CommandGeneratorContext(
                    draft: draft,
                    shell: integratedShell,
                    cwd: workingDirectory,
                    remoteSystemInfo: includesSystemInfo ? remoteSystemInfo : nil
                )
            },
            isCurrent: { [weak self] in
                self?.commandGenerationSnapshotIsCurrent(
                    connectionGeneration: connectionGeneration,
                    revision: revision,
                    shell: integratedShell,
                    workingDirectory: workingDirectory
                ) == true
            },
            generate: { try await generator.generate($0) },
            insert: { [weak self] command in await self?.replaceCurrentDraft(with: command) }
        )
    }

    func cancelCommandGeneration() {
        guard commandGeneration.isRunning || commandDraft.hasPendingRequest else { return }
        commandGeneration.cancel()
        commandDraft.cancel(CancellationError())
    }

    func receiveWorkingDirectory(_ path: String?) {
        let path = path?.isEmpty == false ? path : nil
        guard workingDirectory != path else { return }
        workingDirectory = path
        cancelPendingUpload()
        invalidateCommandGeneration()
    }

    var canGenerateFromCurrentDraft: Bool {
        connected && shellIntegrationAvailable && isShellPromptReady
            && TerminalCommandDraftController.supportedShells.contains(integratedShell ?? "")
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
        try await commandDraft.read(isAvailable: canGenerateFromCurrentDraft) { [weak self] data in
            await self?.writeSSHDirectly(data)
        }
    }

    private func replaceCurrentDraft(with command: String) async {
        await writeSSHDirectly(commandDraft.replacementPayload(for: command))
        terminal.requestFocus()
    }

    private func commandGenerationSnapshotIsCurrent(
        connectionGeneration: UUID,
        revision: UInt64,
        shell: String,
        workingDirectory: String
    ) -> Bool {
        generation == connectionGeneration
            && commandGeneratorRevision == revision
            && integratedShell == shell
            && self.workingDirectory == workingDirectory
            && canGenerateFromCurrentDraft
    }

    private func invalidateCommandGeneration() {
        commandGeneratorRevision &+= 1
        if commandGeneration.isRunning { cancelCommandGeneration() }
    }

    private func resetCommandGeneratorShellState() {
        cancelCommandGeneration()
        integratedShell = nil
        remoteSystemInfo = nil
        isShellPromptReady = false
        shellIntegrationAvailable = false
        workingDirectory = nil
        commandDraft.cancel()
        commandGeneratorRevision &+= 1
    }

    private func showCommandGenerationFailure(_ message: String) {
        commandGeneration.fail(message)
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
            shellIntegrationAvailable = true
            // Installation completes by entering the shell's prompt hook. Treat
            // that authenticated boundary as ready even if the following
            // TermindPrompt OSC is swallowed by the UIKit terminal path.
            isShellPromptReady = true
            invalidateCommandGeneration()
            recordRemoteSystemInfo(systemInfo)
        case .systemInfo(let systemInfo):
            remoteSystemInfo = systemInfo
            invalidateCommandGeneration()
            recordRemoteSystemInfo(systemInfo)
        case .homeResolutionUnavailable:
            break
        case .promptReady:
            guard !isShellPromptReady else { return }
            isShellPromptReady = true
            invalidateCommandGeneration()
        case .commandStarted(let command):
            guard shellIntegrationAvailable else { return }
            isShellPromptReady = false
            invalidateCommandGeneration()
            activeHistoryID = commandHistory.record(command, for: descriptor.hostID)?.id
        case .commandFinished(let status, let duration):
            // CommandFinished is emitted from the prompt hook immediately before
            // cwd and prompt reporting, so it is also a trustworthy recovery
            // point when the separate prompt marker never reaches mobile state.
            if !isShellPromptReady, shellIntegrationAvailable {
                isShellPromptReady = true
                invalidateCommandGeneration()
            }
            guard let id = activeHistoryID else { return }
            commandHistory.recordCompletion(
                for: id, hostID: descriptor.hostID, exitStatus: status, duration: duration)
            activeHistoryID = nil
        case .draft(let draft):
            commandDraft.receive(draft)
        }
    }

    func connect() {
        guard !busy, !connected else { return }
        cancelPendingUpload()
        stopSSHEventConsumer()
        let reconnecting = connection.isRecovering
        let token = UUID()
        generation = token
        activeHistoryID = nil
        resetCommandGeneratorShellState()
        busy = true
        connectionFailure = nil
        status = String(localized: reconnecting ? "Reconnecting" : "Connecting")
        guard let host = hosts.host(descriptor.hostID) else {
            let message = String(localized: "The host is no longer available.")
            connection.stopRecovery()
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
        let progressHandler = connection.progressHandler(attemptID: token) { [weak self] in
            self?.generation == $0
        }
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
                        connection.waitForHostKey(
                            SSHHostKeyPrompt(
                                observation: observation,
                                kind: trusted.isEmpty ? .firstUse : .additionalKey(trustedKeyCount: trusted.count)
                            ),
                            hostID: endpoint.id,
                            fingerprint: observation.fingerprint
                        )
                        status = String(localized: "Waiting for approval")
                        return
                    }
                }
                let preparation = try preparation(for: host)
                let config = try await preparation.resolve()
                guard generation == token, !Task.isCancelled else { return }

                if descriptor.kind == .ssh {
                    let backend = backend
                    let handlers = startSSHEventConsumer(for: token)
                    let session = connectionServices.makeSSHSession(
                        { backend.receive($0) },
                        handlers.exit,
                        handlers.shellIntegration)
                    ssh = session
                    try await connectionServices.connectSSH(
                        session,
                        config,
                        terminalSettings.preferences.shellIntegration,
                        UInt16(clamping: viewport.columns),
                        UInt16(clamping: viewport.rows),
                        progressHandler
                    )
                } else {
                    let client = try await connectionServices.connectSFTP(
                        config, progressHandler,
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
                    let initialPath =
                        reconnecting
                        ? sftpSession.path
                        : host.sftpSessionInitialPath.isEmpty
                            ? try await client.homeDirectory() : host.sftpSessionInitialPath
                    try await sftpSession.attach(
                        fileSystem: client,
                        path: initialPath,
                        connectionGeneration: token,
                        handlesConnectionError: { [weak self] error in
                            self?.handleSFTPConnectionError(error, connection: token) == true
                        },
                        didChangePath: { [weak self] in
                            self?.cancelPendingUpload()
                        }
                    )
                    journey.receive(.connected(host.id))
                }
                guard generation == token, !Task.isCancelled else { return }
                transferConfiguration = config
                submissions.removeAll()
                let wasReconnecting = connection.markConnected()
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
                stopSSHEventConsumer()
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
                        connection.pauseForUserInteraction()
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
                    if (connection.hasConnectedOnce || reconnecting) && !preventsAutomaticReconnect {
                        scheduleReconnect(after: error.localizedDescription)
                    } else {
                        connection.stopRecovery()
                        journey.fail(error.localizedDescription)
                        status = String(localized: "Disconnected")
                    }
                }
                await ssh?.disconnect()
                await sftp?.disconnect()
                ssh = nil
                sftp = nil
                sftpSession.detach()
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
        connection.reconnect.retryNow()
    }

    func stopReconnecting() {
        guard let reconnectState = connection.stopRecovery() else { return }
        cancelPendingUpload()
        stopSSHEventConsumer()
        resetCommandGeneratorShellState()
        connectionResumeIntent = .none
        generation = UUID()
        attempt?.cancel()
        attempt = nil
        let oldSSH = ssh
        let oldSFTP = sftp
        ssh = nil
        sftp = nil
        sftpSession.detach()
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
        stopSSHEventConsumer()
        resetCommandGeneratorShellState()
        let reconnecting = connection.hasConnectedOnce
        connectionResumeIntent = .foreground
        generation = UUID()
        attempt?.cancel()
        attempt = nil
        let oldSSH = ssh
        let oldSFTP = sftp
        ssh = nil
        sftp = nil
        sftpSession.detach()
        busy = false
        connected = false
        transferConfiguration = nil
        activeHistoryID = nil
        authenticationRequired = false
        authenticationPrompt = nil
        connection.clearHostKeyPrompt()
        temporaryKeys.removeAll()
        submissions.removeAll()
        connectionFailure = nil
        operationError = nil
        connection.suspendForForegroundResume(reconnecting: reconnecting)
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
        stopSSHEventConsumer()
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
            connection.resetRecovery()
            status = String(localized: "Disconnected")
            didRequestClose?(id)
        case .failure(let failure):
            handleConnectionFailure(failure.localizedDescription)
        }
    }

    private func handleConnectionFailure(_ message: String) {
        guard connection.hasConnectedOnce else { return }
        scheduleReconnect(after: message)
    }

    private func scheduleReconnect(after message: String) {
        cancelPendingUpload()
        stopSSHEventConsumer()
        resetCommandGeneratorShellState()
        let announcesLoss = connection.scheduleRecovery(after: message) { [weak self] in self?.connect() }
        generation = UUID()
        attempt?.cancel()
        attempt = nil
        let oldSSH = ssh
        let oldSFTP = sftp
        ssh = nil
        sftp = nil
        sftpSession.detach()
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
        guard let observation = connection.pendingHostKey?.observation else { return }
        if remember {
            connection.trustHostKey(observation, using: hosts)
        } else {
            guard connection.useTemporaryHostKey(observation) else { return }
        }
        connect()
    }

    func disconnect() {
        cancelPendingUpload()
        stopSSHEventConsumer()
        resetCommandGeneratorShellState()
        connectionResumeIntent = .none
        connection.disconnect()
        connectionFailure = nil
        operationError = nil
        authenticationRequired = false
        authenticationPrompt = nil
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
        sftpSession.detach()
        Task {
            await oldSSH?.disconnect()
            await oldSFTP?.disconnect()
        }
        busy = false
        connected = false
        status = String(localized: "Disconnected")
    }

    private func startSSHEventConsumer(
        for connectionGeneration: UUID
    ) -> (
        exit: SSHSessionActor.ExitHandler,
        shellIntegration: SSHSessionActor.ShellIntegrationHandler
    ) {
        stopSSHEventConsumer()
        let (events, continuation) = AsyncStream<MobileSSHSessionEvent>.makeStream()
        sshEventContinuation = continuation
        sshEventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self,
                    self.generation == connectionGeneration
                else { break }
                switch event {
                case .exit(let result):
                    self.handleRemoteExit(result)
                case .shellIntegration(let event):
                    self.receiveShellEvent(event)
                }
            }
        }
        return (
            exit: { result in
                continuation.yield(.exit(result))
                continuation.finish()
            },
            shellIntegration: { event in
                continuation.yield(.shellIntegration(event))
            }
        )
    }

    private func recordRemoteSystemInfo(_ systemInfo: RemoteSystemInfo?) {
        hosts.recordRemoteSystemInfo(systemInfo, for: descriptor.hostID)
        guard let systemInfo,
            case .resolved(let distribution) = systemInfo.distributionDetection
        else { return }
        let iconAsset = LinuxDistributionIconCatalog.entry(for: distribution)?.asset
        guard activitySession.iconAsset != iconAsset else { return }
        activitySession.iconAsset = iconAsset
        didChangeState?(activitySession)
    }

    private func stopSSHEventConsumer() {
        sshEventContinuation?.finish()
        sshEventContinuation = nil
        sshEventTask?.cancel()
        sshEventTask = nil
    }

    private var hasActiveConnectionFlow: Bool {
        if connected || busy || connection.isRecovering || authenticationRequired || connection.pendingHostKey != nil {
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
                        await self.sftpSession.openDirectory(self.sftpSession.path)
                    }
                }
                if pendingUpload.ownsClient { await pendingUpload.client.disconnect() }
                guard generation == pendingUpload.connectionGeneration else { return }
                if result.changedRemoteDirectories, descriptor.kind == .sftp {
                    await sftpSession.openDirectory(sftpSession.path)
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

    private func showUploadNotice(_ notice: WorkspaceUploadNotice) {
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
            guard RemoteFileName.isValid(file.name) else { throw CocoaError(.fileWriteInvalidFileName) }
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

    private func handleSFTPConnectionError(_ error: any Error, connection: UUID) -> Bool {
        guard generation == connection, self.connection.hasConnectedOnce, let sftpError = error as? SFTPError else {
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

@MainActor
private final class MobileTerminalRelay {
    weak var owner: MobileWorkspace?
}
