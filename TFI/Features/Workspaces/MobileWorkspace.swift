import Combine
import Foundation
import GhosttyTerminal
import Observation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import UIKit

import struct TermindDomain.Host

private enum MobileWorkspaceConnectionResumeIntent: Equatable {
    case none
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
    var context: SFTPTransferContext
    var connectionGeneration: UUID
}

private struct MobilePendingDownload {
    var batch: SFTPRemoteDownloadBatch
    var connectionGeneration: UUID
}

private struct MobilePendingRemoteCopy {
    var batch: SFTPRemoteCopyBatch
    var connectionGeneration: UUID
}

private struct MobilePendingInitialCommand {
    var command: String
    var recordsInHistory: Bool
}

@MainActor
@Observable
final class MobileWorkspace: Identifiable {
    typealias ID = UUID

    private(set) var descriptor: MobileWorkspaceDescriptor
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
    let sftpChannel: MobileSFTPChannelModel
    let sftpEdits: SFTPEditService?
    let transfers: SFTPTransferCoordinator?
    private var transferContext: SFTPTransferContext?
    private var transferSnapshot: SSHAdditionalConnectionSnapshot?
    private(set) var uploadNotice: WorkspaceUploadNotice?
    private var pendingUpload: MobilePendingUpload?
    private var uploadPreparationTask: Task<Void, Never>?
    private var uploadPreparationID: UUID?
    private var uploadEnqueueTask: Task<Void, Never>?
    private var uploadEnqueueID: UUID?
    private var uploadNoticeTask: Task<Void, Never>?
    private var uploadNoticeID: UUID?
    private var remoteTransferPreparationTask: Task<Void, Never>?
    private var remoteTransferPreparationID: UUID?
    private var pendingDownload: MobilePendingDownload?
    private var pendingRemoteCopy: MobilePendingRemoteCopy?
    let terminalSettings: TerminalSettingsModel
    let commandHistory: CommandHistoryModel
    let sftpHistory: SFTPHistoryModel
    var terminalTextSelection: MobileTerminalTextSelection?
    @ObservationIgnored lazy var find = TerminalFindController(
        perform: { [weak self] in _ = self?.terminal.performBindingAction($0) },
        focus: { [weak self] in self?.terminal.requestFocus() }
    )
    private var activeHistoryID: UUID?
    /// Resolved once at the beginning of each connection attempt.
    private(set) var isShellIntegrationEnabled = true
    private var shellIntegrationAvailable = false
    private var isInitialCommandSubmissionReady = false
    private var pendingCommand: MobilePendingInitialCommand?
    private var commandExcludedFromHistory: String?
    private var pendingInitialSFTPPath: String?
    var pendingInitialCommand: String? { pendingCommand?.command }
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
    var uploadTerminalView: UIView? { descriptor.kind == .ssh ? surfaceOwner.view : nil }
    let terminal: TerminalViewState
    private let backend: InMemoryTerminalSession
    private var ssh: SSHPTYChannel?
    private var sftp: (any SFTPClientProtocol)?
    private var sshEventContinuation: AsyncStream<MobileSSHSessionEvent>.Continuation?
    private var sshEventTask: Task<Void, Never>?
    private var attempt: Task<Void, Never>?
    private var generation = UUID()
    private let hosts: any RemoteSessionHostStore
    private let connectionServices: MobileWorkspaceConnectionServices
    var keyboardAuthentication: SSHKeyboardInteractiveQueue { connection.keyboardAuthentication }
    private let connection: RemoteSessionConnectionController
    private var viewport = InMemoryTerminalViewport(columns: 80, rows: 24)

    var transferConflictCount: Int {
        pendingRemoteCopy?.batch.conflictCount
            ?? pendingDownload?.batch.conflictCount
            ?? pendingUpload?.batch.conflictCount
            ?? 0
    }
    var hasPendingTransferConflict: Bool { transferConflictCount > 0 }

    var sameDirectoryLaunch: MobileWorkspaceDirectoryLaunch? {
        guard connected else { return nil }
        switch descriptor.kind {
        case .ssh:
            guard isShellIntegrationEnabled,
                shellIntegrationAvailable,
                let workingDirectory,
                !workingDirectory.isEmpty
            else { return nil }
            return MobileWorkspaceDirectoryLaunch(
                hostID: descriptor.hostID,
                kind: .sftp,
                path: RemotePath.normalized(workingDirectory)
            )
        case .sftp:
            guard !sftpChannel.path.isEmpty else { return nil }
            return MobileWorkspaceDirectoryLaunch(
                hostID: descriptor.hostID,
                kind: .ssh,
                path: RemotePath.normalized(sftpChannel.path)
            )
        }
    }

    var uploadDestination: String? {
        switch descriptor.kind {
        case .ssh:
            guard uploadTargetProblem == nil, let workingDirectory else { return nil }
            return RemotePath.normalized(workingDirectory)
        case .sftp:
            guard uploadTargetProblem == nil else { return nil }
            return sftpChannel.path
        }
    }

    var uploadTargetProblem: String? {
        switch descriptor.kind {
        case .ssh:
            return TerminalUploadAvailability.problem(
                isConnected: connected,
                hasTransferConfiguration: transferSnapshot != nil,
                isWorkingDirectoryPending: workingDirectory == nil,
                workingDirectory: workingDirectory
            )
        case .sftp:
            guard connected, transferSnapshot != nil, sftp != nil else {
                return String(localized: "The SFTP channel is not connected.")
            }
            return nil
        }
    }
    private var connectionResumeIntent: MobileWorkspaceConnectionResumeIntent

    init(
        descriptor: MobileWorkspaceDescriptor, hosts: any RemoteSessionHostStore,
        transfers: SFTPTransferCoordinator? = nil,
        sftpEdits: SFTPEditService? = nil,
        terminalSettings: TerminalSettingsModel = TerminalSettingsModel(),
        commandHistory: CommandHistoryModel = CommandHistoryModel(),
        sftpHistory: SFTPHistoryModel = SFTPHistoryModel(),
        connectionServices: MobileWorkspaceConnectionServices = .live,
        reconnectController: SessionReconnectController = SessionReconnectController(),
        initialCommand: String? = nil,
        recordsInitialCommandInHistory: Bool = true,
        initialSFTPPath: String? = nil
    ) {
        self.terminalSettings = terminalSettings
        self.commandHistory = commandHistory
        self.sftpHistory = sftpHistory
        sftpChannel = MobileSFTPChannelModel(hostID: descriptor.hostID, history: sftpHistory)
        self.transfers = transfers
        self.sftpEdits = sftpEdits
        self.descriptor = descriptor
        self.hosts = hosts
        activitySession = WorkspaceActivityAttributes.Session(
            id: descriptor.id, title: descriptor.title, kind: descriptor.kind.rawValue,
            connected: false,
            iconAsset: LinuxDistributionIconCatalog.entry(
                for: hosts.host(descriptor.hostID)?.detectedDistribution)?.asset)
        pendingCommand = initialCommand.map {
            MobilePendingInitialCommand(command: $0, recordsInHistory: recordsInitialCommandInHistory)
        }
        pendingInitialSFTPPath = initialSFTPPath.flatMap { path in
            path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : RemotePath.normalized(path)
        }
        self.connectionServices = connectionServices
        connection = RemoteSessionConnectionController(reconnect: reconnectController)
        connectionResumeIntent = .none
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
        terminal.onTextSelectionRequest = { [weak relay] request in
            relay?.owner?.terminalTextSelection = MobileTerminalTextSelection(request)
        }
        workingDirectoryObservation = terminal.$workingDirectory.sink { [weak relay] path in
            Task { @MainActor in
                relay?.owner?.receiveWorkingDirectory(path)
            }
        }
        surfaceOwner.bindFind(find)
    }

    func dismissTerminalTextSelection() {
        terminalTextSelection = nil
    }

    @discardableResult
    func rename(to proposedTitle: String) -> Bool {
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != descriptor.title else { return false }
        descriptor.title = title
        activitySession.title = title
        didChangeState?(activitySession)
        return true
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
                && staged?.requiresPasswordReentry != true
                && staged?.passphrase == nil,
            mode: authenticationMode)
    }

    var hostKeyPrompt: SSHHostKeyPrompt? { connection.pendingHostKey }

    private func preparation(
        for host: Host, submissions: [UUID: SSHAuthenticationSubmission]
    ) throws -> SSHConnectionPreparation {
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
            guard let passphrase, !passphrase.isEmpty else { return }
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

    func insertTerminalText(_ text: String) {
        guard connected else { return }
        _ = terminal.paste(text: text)
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
        let includesSystemInfo = isShellIntegrationEnabled
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
        connected && isShellIntegrationEnabled && shellIntegrationAvailable && isShellPromptReady
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
        isInitialCommandSubmissionReady = false
        workingDirectory = nil
        commandExcludedFromHistory = nil
        commandDraft.cancel()
        commandGeneratorRevision &+= 1
    }

    private func showCommandGenerationFailure(_ message: String) {
        commandGeneration.fail(message)
    }

    func receiveShellEvent(_ event: SSHShellIntegrationEvent) {
        guard isShellIntegrationEnabled else {
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
            isInitialCommandSubmissionReady = true
            invalidateCommandGeneration()
            recordRemoteSystemInfo(systemInfo)
            submitPendingInitialCommandIfReady()
        case .systemInfo(let systemInfo):
            remoteSystemInfo = systemInfo
            invalidateCommandGeneration()
            recordRemoteSystemInfo(systemInfo)
        case .homeResolutionUnavailable:
            isInitialCommandSubmissionReady = true
            submitPendingInitialCommandIfReady()
        case .promptReady:
            if !isShellPromptReady {
                isShellPromptReady = true
                invalidateCommandGeneration()
            }
            isInitialCommandSubmissionReady = true
            submitPendingInitialCommandIfReady()
        case .commandStarted(let command):
            guard shellIntegrationAvailable else { return }
            let command = CommandHistoryEntry.normalizingLineContinuations(in: command)
            isShellPromptReady = false
            invalidateCommandGeneration()
            if command == commandExcludedFromHistory {
                commandExcludedFromHistory = nil
                activeHistoryID = nil
            } else {
                activeHistoryID = commandHistory.record(command, for: descriptor.hostID)?.id
            }
        case .commandFinished(let status, let duration):
            // CommandFinished is emitted from the prompt hook immediately before
            // cwd and prompt reporting, so it is also a trustworthy recovery
            // point when the separate prompt marker never reaches mobile state.
            if !isShellPromptReady, shellIntegrationAvailable {
                isShellPromptReady = true
                invalidateCommandGeneration()
            }
            isInitialCommandSubmissionReady = true
            submitPendingInitialCommandIfReady()
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
        isShellIntegrationEnabled = host.shellIntegrationMode.isEnabled(
            globalSetting: terminalSettings.preferences.shellIntegration)
        let route = hosts.route(for: host)
        journey.begin(
            host: host, route: route,
            purpose: descriptor.kind == .ssh ? .sshSession : .sftpChannel,
            username: hosts.identity(for: host)?.username,
            mode: reconnecting ? .reconnection : .connection)
        if let passwordHost = submissions.firstHostRequiringPassword(in: route) {
            authenticationRequired = true
            authenticationMode = .localIdentity
            authenticationHostID = passwordHost.id
            username =
                submissions[passwordHost.id]?.username
                ?? hosts.identity(for: passwordHost)?.username ?? ""
            authenticationPrompt = makeAuthenticationPrompt()
            journey.waitForLocalIdentity(at: passwordHost.id)
            busy = false
            return
        }
        if let passphraseHost = submissions.firstHostRequiringPassphrase(
            in: route, key: hosts.key
        ) {
            authenticationRequired = true
            authenticationMode = .localIdentity
            authenticationHostID = passphraseHost.id
            username =
                submissions[passphraseHost.id]?.username
                ?? hosts.identity(for: passphraseHost)?.username ?? ""
            authenticationPrompt = makeAuthenticationPrompt()
            journey.waitForLocalPassphrase(at: passphraseHost.id)
            busy = false
            return
        }
        let attemptSubmissions = submissions.takeAuthenticationSecrets()
        let progressHandler = connection.progressHandler(attemptID: token) { [weak self] in
            self?.generation == $0
        }
        connection.clearHostKeyPrompt()
        attempt = Task { [weak self, weak hosts] in
            guard let self, let hosts else { return }
            defer { if generation == token { busy = false } }
            guard generation == token, !Task.isCancelled else { return }
            do {
                let preparation = try preparation(for: host, submissions: attemptSubmissions)
                let config = try await preparation.resolve(
                    trustPolicy: .allowChallenge
                )
                guard generation == token, !Task.isCancelled else { return }
                let request = SSHConnectionRequest(
                    configuration: config,
                    authorizeHostKey: { [weak self, weak hosts] challenge in
                        guard let self, let hosts else { throw CancellationError() }
                        return await self.connection.authorizeHostKey(
                            challenge, using: hosts
                        )
                    },
                    keyboardInteractive: { [weak self] challenge in
                        guard let self, await self.generation == token else { throw CancellationError() }
                        return try await self.connection.answerKeyboardInteractive(challenge)
                    }
                )

                if descriptor.kind == .ssh {
                    let backend = backend
                    let handlers = startSSHEventConsumer(for: token)
                    let session = connectionServices.makePTYChannel(
                        { backend.receive($0) },
                        handlers.exit,
                        handlers.shellIntegration)
                    ssh = session
                    try await connectionServices.connectSSH(
                        session,
                        request,
                        isShellIntegrationEnabled,
                        UInt16(clamping: viewport.columns),
                        UInt16(clamping: viewport.rows),
                        progressHandler
                    )
                } else {
                    let client = try await connectionServices.connectSFTP(
                        request, progressHandler,
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
                    let initialPath: String
                    if reconnecting {
                        initialPath = sftpChannel.path
                    } else if let pendingInitialSFTPPath {
                        initialPath = pendingInitialSFTPPath
                    } else if host.sftpChannelInitialPath.isEmpty {
                        initialPath = try await client.homeDirectory()
                    } else {
                        initialPath = host.sftpChannelInitialPath
                    }
                    try await sftpChannel.attach(
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
                    pendingInitialSFTPPath = nil
                    journey.receive(.connected(host.id))
                }
                guard generation == token, !Task.isCancelled else { return }
                let additionalSnapshot = hosts.additionalConnectionSnapshot(from: config)
                transferSnapshot = additionalSnapshot
                if let sftp {
                    transferContext = SFTPTransferContext(
                        snapshot: additionalSnapshot, hostStore: hosts, channel: sftp)
                }
                submissions.removeAll()
                let wasReconnecting = connection.markConnected()
                connected = true
                status = String(localized: "Connected")
                journey.succeed()
                if wasReconnecting, descriptor.kind == .ssh {
                    appendTerminalNotice(String(localized: "Reconnected; a new remote shell has started."))
                }
                if descriptor.kind == .ssh {
                    if !isShellIntegrationEnabled {
                        isInitialCommandSubmissionReady = true
                    }
                    submitPendingInitialCommandIfReady()
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
                if let transferContext { await transferContext.retire() } else { await sftp?.disconnect() }
                transferContext = nil
                ssh = nil
                sftp = nil
                sftpChannel.detach()
            }
        }
    }

    /// Consumes the launch-only command before it is written. Reconnects and
    /// restored descriptors therefore cannot replay a script.
    func consumePendingInitialCommand() -> String? {
        guard let pendingCommand else { return nil }
        self.pendingCommand = nil
        if !pendingCommand.recordsInHistory {
            commandExcludedFromHistory = CommandHistoryEntry.normalizingLineContinuations(
                in: pendingCommand.command
            )
        }
        return pendingCommand.command
    }

    private func submitPendingInitialCommandIfReady() {
        guard descriptor.kind == .ssh, connected, isInitialCommandSubmissionReady,
            let session = ssh, let command = consumePendingInitialCommand()
        else { return }
        let token = generation
        let data = Data((command + "\r").utf8)
        Task { [weak self] in
            guard let self, generation == token, connected, ssh === session else { return }
            await connectionServices.writeSSH(session, data)
        }
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
        let oldTransferContext = transferContext
        transferContext = nil
        ssh = nil
        sftp = nil
        sftpChannel.detach()
        busy = false
        connected = false
        transferSnapshot = nil
        status = String(localized: "Disconnected")
        connectionFailure = reconnectState.lastError
        journey.fail(reconnectState.lastError)
        Task {
            await oldSSH?.disconnect()
            if let oldTransferContext { await oldTransferContext.retire() } else { await oldSFTP?.disconnect() }
        }
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
        let oldTransferContext = transferContext
        transferContext = nil
        ssh = nil
        sftp = nil
        sftpChannel.detach()
        busy = false
        connected = false
        transferSnapshot = nil
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
            if let oldTransferContext { await oldTransferContext.retire() } else { await oldSFTP?.disconnect() }
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
        transferSnapshot = nil
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
        let oldTransferContext = transferContext
        transferContext = nil
        ssh = nil
        sftp = nil
        sftpChannel.detach()
        busy = false
        connected = false
        transferSnapshot = nil
        status = String(localized: "Reconnecting")
        if announcesLoss, descriptor.kind == .ssh {
            appendTerminalNotice(String(localized: "Connection lost; reconnecting…"))
        }
        if let host = hosts.host(descriptor.hostID) {
            journey.begin(
                host: host, route: hosts.route(for: host),
                purpose: descriptor.kind == .ssh ? .sshSession : .sftpChannel,
                username: hosts.identity(for: host)?.username, mode: .reconnection)
        }
        Task {
            await oldSSH?.disconnect()
            if let oldTransferContext { await oldTransferContext.retire() } else { await oldSFTP?.disconnect() }
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
        pendingCommand = nil
        pendingInitialSFTPPath = nil
        commandExcludedFromHistory = nil
        generation = UUID()
        attempt?.cancel()
        attempt = nil
        transferSnapshot = nil
        let oldSSH = ssh
        let oldSFTP = sftp
        let oldTransferContext = transferContext
        transferContext = nil
        ssh = nil
        sftp = nil
        sftpChannel.detach()
        Task {
            await oldSSH?.disconnect()
            if let oldTransferContext { await oldTransferContext.releaseOwner() } else { await oldSFTP?.disconnect() }
        }
        busy = false
        connected = false
        status = String(localized: "Disconnected")
    }

    private func startSSHEventConsumer(
        for connectionGeneration: UUID
    ) -> (
        exit: SSHPTYChannel.ExitHandler,
        shellIntegration: SSHPTYChannel.ShellIntegrationHandler
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
            purpose: descriptor.kind == .ssh ? .sshSession : .sftpChannel,
            username: hosts.identity(for: host)?.username, mode: mode)
    }

    @discardableResult
    func prepareUpload(_ urls: [URL]) -> Bool {
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { return false }
        cancelPendingUpload()
        guard transfers != nil, let snapshot = transferSnapshot,
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

        let connectionGeneration = generation
        let preparationID = UUID()
        uploadPreparationID = preparationID
        uploadNotice = .preparing(destination)
        uploadPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if uploadPreparationID == preparationID {
                    uploadPreparationTask = nil
                    uploadPreparationID = nil
                }
            }
            var client: (any SFTPClientProtocol)?
            var ownsClient = false
            do {
                if descriptor.kind == .sftp {
                    guard let sftp else { throw SFTPError.notConnected }
                    client = sftp
                } else {
                    client = try await connectionServices.connectSFTP(
                        hosts.additionalConnectionRequest(from: snapshot), nil, nil)
                    ownsClient = true
                }
                try Task.checkCancellation()
                guard uploadPreparationID == preparationID,
                    generation == connectionGeneration, uploadDestination == destination,
                    let client
                else { throw CancellationError() }
                let batch = try await SFTPLocalUploadPlanner.prepare(
                    urls,
                    destination: destination,
                    client: client
                )
                try Task.checkCancellation()
                guard uploadPreparationID == preparationID,
                    generation == connectionGeneration, uploadDestination == destination
                else {
                    throw CancellationError()
                }
                guard !batch.isEmpty else {
                    throw SFTPError.localFile(String(localized: "No uploadable files were found."))
                }
                let context: SFTPTransferContext
                if ownsClient {
                    context = SFTPTransferContext(
                        snapshot: snapshot, hostStore: hosts,
                        channel: client, primaryRole: .donatedConnection)
                } else {
                    guard let existing = transferContext else { throw SFTPError.notConnected }
                    context = existing
                }
                pendingUpload = MobilePendingUpload(
                    batch: batch,
                    destination: destination,
                    client: client,
                    ownsClient: ownsClient,
                    context: context,
                    connectionGeneration: connectionGeneration
                )
                if batch.conflictCount > 0 {
                    if uploadNotice?.isRejected != true { uploadNotice = nil }
                } else {
                    enqueuePendingUpload(.replace)
                }
            } catch is CancellationError {
                if ownsClient { await client?.disconnect() }
                if uploadPreparationID == preparationID { uploadNotice = nil }
            } catch {
                if ownsClient { await client?.disconnect() }
                guard uploadPreparationID == preparationID, generation == connectionGeneration else { return }
                reportUploadFailure(error.localizedDescription)
            }
        }
        return true
    }

    func remoteCopySource(for file: RemoteFile) -> SFTPRemoteCopySource? {
        guard descriptor.kind == .sftp, connected, let transferContext else {
            return nil
        }
        return SFTPRemoteCopySource(
            hostID: descriptor.hostID,
            connection: .context(transferContext),
            files: [file]
        )
    }

    func prepareRemoteCopy(_ payload: SFTPRemoteItemsPayload) {
        guard let transfers, transferSnapshot != nil,
            let sftp, connected
        else {
            operationError = String(localized: "The SFTP connection is not available.")
            return
        }
        cancelPendingUpload()
        let connectionGeneration = generation
        let preparationID = UUID()
        remoteTransferPreparationID = preparationID
        remoteTransferPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if remoteTransferPreparationID == preparationID {
                    remoteTransferPreparationTask = nil
                    remoteTransferPreparationID = nil
                }
            }
            do {
                let batch = try await SFTPRemoteCopyPlanner.prepare(
                    payload, destination: sftpChannel.path,
                    destinationHostID: descriptor.hostID,
                    client: sftp, coordinator: transfers
                )
                try Task.checkCancellation()
                guard remoteTransferPreparationID == preparationID,
                    generation == connectionGeneration
                else { return }
                pendingRemoteCopy = MobilePendingRemoteCopy(
                    batch: batch,
                    connectionGeneration: connectionGeneration
                )
                if batch.conflictCount == 0 { enqueuePendingTransfer(.replace) }
            } catch is CancellationError {
            } catch {
                guard remoteTransferPreparationID == preparationID else { return }
                operationError = error.localizedDescription
            }
        }
    }

    func prepareDownload(_ file: RemoteFile, to destination: URL) {
        guard transfers != nil, transferSnapshot != nil,
            let sftp, connected
        else {
            operationError = String(localized: "The SFTP connection is not available.")
            return
        }
        cancelPendingUpload()
        let connectionGeneration = generation
        let preparationID = UUID()
        remoteTransferPreparationID = preparationID
        remoteTransferPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if remoteTransferPreparationID == preparationID {
                    remoteTransferPreparationTask = nil
                    remoteTransferPreparationID = nil
                }
            }
            do {
                let batch = try await SFTPRemoteDownloadPlanner.prepare(
                    [file], destination: destination, client: sftp
                )
                try Task.checkCancellation()
                guard remoteTransferPreparationID == preparationID,
                    generation == connectionGeneration
                else { return }
                pendingDownload = MobilePendingDownload(
                    batch: batch,
                    connectionGeneration: connectionGeneration
                )
                if batch.conflictCount == 0 { enqueuePendingTransfer(.replace) }
            } catch is CancellationError {
            } catch {
                guard remoteTransferPreparationID == preparationID else { return }
                operationError = error.localizedDescription
            }
        }
    }

    func enqueuePendingTransfer(_ policy: TransferConflictPolicy) {
        if let pendingRemoteCopy, let transfers, let sftp {
            self.pendingRemoteCopy = nil
            guard generation == pendingRemoteCopy.connectionGeneration, let transferContext else { return }
            let generation = pendingRemoteCopy.connectionGeneration
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await SFTPRemoteCopyPlanner.enqueue(
                        pendingRemoteCopy.batch, policy: policy,
                        destinationHostID: descriptor.hostID,
                        destinationConnection: .context(transferContext),
                        client: sftp, coordinator: transfers
                    ) { [weak self] state in
                        guard state == .completed else { return }
                        Task { @MainActor in
                            guard let self, self.generation == generation else { return }
                            await self.sftpChannel.reload()
                        }
                    }
                } catch { operationError = error.localizedDescription }
            }
            return
        }
        if let pendingDownload, let transfers {
            self.pendingDownload = nil
            guard generation == pendingDownload.connectionGeneration, let transferContext else { return }
            do {
                try SFTPRemoteDownloadPlanner.enqueue(
                    pendingDownload.batch, policy: policy,
                    hostID: descriptor.hostID,
                    connection: .context(transferContext),
                    coordinator: transfers
                ) { [sftpHistory, hostID = descriptor.hostID] path, state in
                    guard state == .completed else { return }
                    sftpHistory.record(kind: .file, path: path, for: hostID)
                }
            } catch { operationError = error.localizedDescription }
            return
        }
        enqueuePendingUpload(policy)
    }

    func cancelPendingRemoteTransfer() {
        remoteTransferPreparationID = nil
        remoteTransferPreparationTask?.cancel()
        remoteTransferPreparationTask = nil
        pendingDownload = nil
        pendingRemoteCopy = nil
    }

    func enqueuePendingUpload(_ policy: TransferConflictPolicy) {
        guard let pendingUpload, let transfers else { return }
        self.pendingUpload = nil
        uploadEnqueueID = nil
        uploadEnqueueTask?.cancel()
        let enqueueID = UUID()
        uploadEnqueueID = enqueueID
        uploadEnqueueTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if uploadEnqueueID == enqueueID {
                    uploadEnqueueTask = nil
                    uploadEnqueueID = nil
                }
            }
            do {
                let result = try await SFTPLocalUploadPlanner.enqueue(
                    pendingUpload.batch,
                    policy: policy,
                    hostID: descriptor.hostID,
                    connection: .context(pendingUpload.context),
                    client: pendingUpload.client,
                    coordinator: transfers
                ) { [weak self] state in
                    guard state == .completed else { return }
                    Task { @MainActor in
                        guard let self,
                            self.descriptor.kind == .sftp,
                            self.generation == pendingUpload.connectionGeneration
                        else { return }
                        await self.sftpChannel.openDirectory(self.sftpChannel.path)
                    }
                }
                if pendingUpload.ownsClient { await pendingUpload.context.releaseOwner() }
                guard uploadEnqueueID == enqueueID,
                    generation == pendingUpload.connectionGeneration
                else { return }
                if result.changedRemoteDirectories, descriptor.kind == .sftp {
                    await sftpChannel.openDirectory(sftpChannel.path)
                }
                showUploadNotice(
                    .queued(pendingUpload.batch.rootCount, pendingUpload.destination)
                )
            } catch is CancellationError {
                if pendingUpload.ownsClient { await pendingUpload.context.releaseOwner() }
                if uploadEnqueueID == enqueueID { uploadNotice = nil }
            } catch {
                if pendingUpload.ownsClient { await pendingUpload.context.releaseOwner() }
                guard uploadEnqueueID == enqueueID, generation == pendingUpload.connectionGeneration else { return }
                reportUploadFailure(error.localizedDescription)
            }
        }
    }

    func cancelPendingUpload() {
        cancelPendingRemoteTransfer()
        uploadPreparationID = nil
        uploadPreparationTask?.cancel()
        uploadPreparationTask = nil
        uploadEnqueueID = nil
        uploadEnqueueTask?.cancel()
        uploadEnqueueTask = nil
        uploadNoticeID = nil
        uploadNoticeTask?.cancel()
        uploadNoticeTask = nil
        uploadNotice = nil
        guard let pendingUpload else { return }
        self.pendingUpload = nil
        if pendingUpload.ownsClient {
            Task { await pendingUpload.context.releaseOwner() }
        }
    }

    func reportUploadFailure(_ message: String) {
        if descriptor.kind == .ssh {
            showUploadNotice(.rejected(message))
        } else {
            uploadNotice = nil
            operationError = message
        }
    }

    private func showUploadNotice(_ notice: WorkspaceUploadNotice) {
        // A partially loaded drop can enqueue its readable files while its failure is still visible.
        if case .queued = notice, uploadNotice?.isRejected == true { return }
        uploadNoticeID = nil
        uploadNoticeTask?.cancel()
        let noticeID = UUID()
        uploadNoticeID = noticeID
        uploadNotice = notice
        uploadNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(notice.isRejected ? 3 : 2))
            guard !Task.isCancelled, self?.uploadNoticeID == noticeID,
                self?.uploadNotice == notice
            else { return }
            self?.uploadNotice = nil
            self?.uploadNoticeTask = nil
            self?.uploadNoticeID = nil
        }
    }

    @discardableResult
    func preview(_ file: RemoteFile, completion: @escaping (URL) -> Void) -> Bool {
        guard let transfers, let transferContext, connected, !file.isDirectory else {
            return false
        }
        if let sftpEdits, let sftp {
            Task {
                do {
                    let url = try await sftpEdits.open(
                        file, hostID: descriptor.hostID, connection: .context(transferContext), client: sftp)
                    sftpHistory.record(kind: .file, path: file.path, for: descriptor.hostID)
                    completion(url)
                } catch { operationError = error.localizedDescription }
            }
            return true
        }
        do {
            guard RemoteFileName.isValid(file.name) else { throw CocoaError(.fileWriteInvalidFileName) }
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "TermindDownloads", directoryHint: .isDirectory
            )
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let localURL = directory.appending(path: file.name)
            transfers.enqueue(
                direction: .download, batchID: UUID(), localURL: localURL,
                remotePath: file.path, byteCount: file.size, hostID: descriptor.hostID,
                connection: .context(transferContext), scopedRoot: directory, overwrite: false
            ) { [sftpHistory, hostID = descriptor.hostID, path = file.path] state in
                guard state == .completed else { return }
                sftpHistory.record(kind: .file, path: path, for: hostID)
                completion(localURL)
            }
            return true
        } catch {
            operationError = error.localizedDescription
            return false
        }
    }

    func uploadEdit(_ id: UUID, replacing: Bool) async -> Bool {
        guard connected, let sftpEdits, let sftp, let transferContext else { return false }
        return await sftpEdits.upload(id, connection: .context(transferContext), client: sftp, replacing: replacing) {
            [weak self] in
            Task { await self?.sftpChannel.reload() }
        }
    }

    func importEditedCopy(_ source: URL, for id: UUID) async {
        guard let edits = sftpEdits, let file = edits.model.file(id), file.hostID == descriptor.hostID else { return }
        do {
            let copy = try await MobileSFTPEditedCopyImporter().stage(source, matching: file.localURL)
            defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
            guard let current = edits.model.file(id), !current.isInvalidated,
                !current.isPreparing, current.transferID == nil
            else { throw SFTPEditFailure.unavailable }
            _ = try FileManager.default.replaceItemAt(current.localURL, withItemAt: copy)
            await edits.recheck()
        } catch { operationError = error.localizedDescription }
    }

    func reopenHistoryFile(at path: String, completion: @escaping (URL) -> Void = { _ in }) async -> Bool {
        guard let sftp, connected else {
            operationError = String(localized: "The SFTP connection is not available.")
            return false
        }
        let connectionGeneration = generation
        do {
            let file = try await sftp.attributes(at: path)
            guard generation == connectionGeneration, connected else { return false }
            guard let file, !file.isDirectory else {
                operationError = String(localized: "The remote file is no longer available.")
                return false
            }
            return preview(file, completion: completion)
        } catch {
            if !handleSFTPConnectionError(error, connection: connectionGeneration) {
                operationError = error.localizedDescription
            }
            return false
        }
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
        guard size.columns > 0, size.rows > 0, size.widthPixels > 0, size.heightPixels > 0 else { return }
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
