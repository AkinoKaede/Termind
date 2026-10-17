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
    let id = UUID()
    var batch: SFTPLocalUploadBatch
    var destination: String
    var homeDirectory: String?
    var client: any SFTPClientProtocol
    var ownsClient: Bool
    var context: SFTPTransferContext
    var connectionGeneration: UUID
    var insertPaths: Bool
    var terminalContext: TerminalContextCoordinator.Ticket?
}

private struct MobilePendingDownload {
    let id = UUID()
    var batch: SFTPRemoteDownloadBatch
    var connectionGeneration: UUID
}

private struct MobilePendingRemoteCopy {
    let id = UUID()
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
    let sessionPersistence = RemoteSessionCoordinator()
    @ObservationIgnored private(set) var activitySession: WorkspaceActivityAttributes.Session
    @ObservationIgnored var didChangeState: ((WorkspaceActivityAttributes.Session) -> Void)?
    @ObservationIgnored var didRequestClose: ((ID) -> Void)?
    private(set) var status = String(localized: AppStrings.Connections.disconnected)
    private(set) var connected = false {
        didSet {
            if !connected { commandMonitor.endConnection() }
            guard activitySession.connected != connected else { return }
            activitySession.connected = connected
            didChangeState?(activitySession)
        }
    }
    private(set) var busy = false
    var reconnectState: ReconnectState? { connection.reconnectState }
    var journey: ConnectionJourney { connection.journey }
    var acceptsTerminalInput: Bool {
        !transport.isResumable
            || (!journey.isPresented
                && transportState != .recovering && transportState != .suspended
                && transportState != .failed && transportState != .ended && transportState != .closed)
    }
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
    private var proxySubmissions: [UUID: SSHProxyAuthenticationSubmission] = [:]
    let sftpChannel: MobileSFTPChannelModel
    let sftpEdits: SFTPEditService?
    let transfers: SFTPTransferCoordinator?
    private var transferContext: SFTPTransferContext?
    private var transferSnapshot: SSHAdditionalConnectionSnapshot?
    var resumeCheckpoint: TerminalTransportCheckpoint?
    var requiresTransportRecovery = false
    var terminalRecoveryStore: TerminalRecoveryStore = .shared
    private var restoringTransport = false
    private var resumeUsername: String?
    private(set) var transportState: ResumableTerminalState?
    var recoveryID: UUID { id }
    private var recoveryLease: UUID?
    private var recoveryRecord: TerminalRecoveryRecord?
    private var transportSuspension: Task<Void, Never>?
    private var transport: HostTerminalProtocol { descriptor.kind.terminalProtocol ?? .ssh }
    private var connectionPurpose: ConnectionPurpose {
        descriptor.kind.terminalProtocol.map(ConnectionPurpose.terminal) ?? .sftpChannel
    }
    var restorationDescriptor: MobileWorkspaceDescriptor {
        var result = descriptor
        result.remoteSession = sessionPersistence.attachment
        return result
    }
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
    @ObservationIgnored lazy var find = TerminalFindController(
        perform: { [weak self] in _ = self?.terminal.performBindingAction($0) },
        focus: { [weak self] in self?.terminal.requestFocus() }
    )
    let commandMonitor = TerminalCommandMonitor()
    private var commandObservation: TerminalCommandObservation?
    private var activeHistoryID: UUID?
    let terminalContext = TerminalContextCoordinator()
    private var hasRuntimeContext = false
    private var historyCharset: RemoteCharset = .utf8
    private var contextHistory: [TerminalContextIdentity: UUID] = [:]
    /// Resolved once at the beginning of each connection attempt.
    private(set) var isShellIntegrationEnabled = true
    private var shellIntegrationAvailable = false
    private var isInitialCommandSubmissionReady = false
    private var initialCommandStartupTicket: SSHOrdinaryStartupTicket?
    private var pendingCommand: MobilePendingInitialCommand?
    /// Re-resolved from the Host and Snippet library for each physical terminal shell.
    private var pendingConnectionStartupCommand: MobilePendingInitialCommand?
    private var commandExcludedFromHistory: String?
    private var pendingInitialSFTPPath: String?
    private var externalSFTPResourcePath: String?
    private var externalSFTPMustBeDirectory = false
    private var transientHost: Host?
    private var connectionRoute: SSHConnectionRoute?
    private var usernameHint: String?
    private let connectionOrigin: RemoteConnectionOrigin
    var isExternalTemporaryConnection: Bool { !connectionOrigin.allowsPersistence }
    var presentationHost: Host? { connectionHost(descriptor.hostID) }
    var temporaryLoginAddress: String? {
        guard hosts.host(descriptor.hostID) == nil, let host = presentationHost else { return nil }
        let connectionProtocol: HostTerminalProtocol = descriptor.kind == .telnet ? .telnet : .ssh
        let address = host.displayAddress(for: connectionProtocol)
        guard let usernameHint, !usernameHint.isEmpty else { return address }
        return "\(usernameHint)@\(address)"
    }
    private var advisoryTelnetPassword: SSHSecret?
    private(set) var pendingExternalPreviewURL: URL?
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
    private var bellObservation: TerminalBellObservation?
    private let surfaceOwner = MobileTerminalSurface()
    var uploadConnectionGeneration: UUID { generation }

    func configureTerminalUpload(files: (() -> Void)?, photos: (() -> Void)? = nil) {
        surfaceOwner.view.uploadFiles = descriptor.kind.isSSHTerminal ? files : nil
        surfaceOwner.view.uploadPhotos = descriptor.kind.isSSHTerminal ? photos : nil
        surfaceOwner.view.canUploadFiles = { [weak self] in self?.uploadTargetProblem == nil && self != nil }
    }

    var uploadTerminalView: UIView? { descriptor.kind.isSSHTerminal ? surfaceOwner.view : nil }
    let terminal: TerminalViewState
    private let backend: InMemoryTerminalSession

    func configureTerminalBell(_ ring: @escaping @MainActor () -> Void) {
        guard descriptor.kind != .sftp else { return }
        bellObservation = TerminalBellObservation(state: terminal, ring: ring)
    }

    func readViewportText() -> String? {
        backend.readViewportText()
    }
    private var ssh: SSHPTYChannel?
    private var telnet: TelnetConnection?
    private var sftp: (any SFTPClientProtocol)?
    private var sshEventContinuation: AsyncStream<MobileSSHSessionEvent>.Continuation?
    private var sshEventTask: Task<Void, Never>?
    private var attempt: Task<Void, Never>?
    private var generation = UUID() {
        didSet { commandHistory.cancelLoading() }
    }
    private let hosts: any RemoteSessionHostStore
    private let connectionServices: MobileWorkspaceConnectionServices
    var securityKeySigning: SecurityKeySigningCoordinator { connection.securityKeySigning }
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

    var transferConflictID: UUID? {
        guard hasPendingTransferConflict else { return nil }
        return pendingRemoteCopy?.id ?? pendingDownload?.id ?? pendingUpload?.id
    }

    /// SwiftUI can write the dialog binding before invoking its button action.
    /// Let that action consume the request first, and never cancel a replacement.
    func dismissTransferConflict(_ id: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, transferConflictID == id else { return }
            cancelPendingUpload()
        }
    }

    var sameDirectoryLaunch: MobileWorkspaceDirectoryLaunch? {
        guard connected else { return nil }
        switch descriptor.kind {
        case .ssh, .mosh, .eternalTerminal:
            guard isShellIntegrationEnabled,
                shellIntegrationAvailable || (hasRuntimeContext && terminalContext.active?.directory != nil),
                let workingDirectory,
                !workingDirectory.isEmpty
            else { return nil }
            return MobileWorkspaceDirectoryLaunch(
                hostID: descriptor.hostID,
                kind: .sftp,
                path: RemotePath.normalized(workingDirectory)
            )
        case .sftp:
            guard !sftpChannel.path.isEmpty, let host = connectionHost(descriptor.hostID),
                host.sshEnabled, let transport = host.preferredTerminalProtocol
            else { return nil }
            return MobileWorkspaceDirectoryLaunch(
                hostID: descriptor.hostID,
                kind: .terminal(transport),
                path: RemotePath.normalized(sftpChannel.path)
            )
        case .telnet:
            return nil
        }
    }

    var uploadDestination: String? {
        switch descriptor.kind {
        case .ssh, .mosh, .eternalTerminal:
            guard uploadTargetProblem == nil, let workingDirectory else { return nil }
            return RemotePath.normalized(workingDirectory)
        case .sftp:
            guard uploadTargetProblem == nil else { return nil }
            return sftpChannel.path
        case .telnet:
            return nil
        }
    }

    var uploadTargetProblem: String? {
        switch descriptor.kind {
        case .ssh, .mosh, .eternalTerminal:
            return TerminalUploadAvailability.problem(
                isConnected: connected,
                hasTransferConfiguration: transferSnapshot != nil,
                isWorkingDirectoryPending: workingDirectory == nil,
                workingDirectory: workingDirectory
            )
        case .sftp:
            guard connected, transferSnapshot != nil, sftp != nil else {
                return String(localized: AppStrings.Workspace.theSftpChannelIsNotConnected)
            }
            return nil
        case .telnet:
            return String(localized: AppStrings.Workspace.telnetDoesNotSupportFileUpload)
        }
    }
    private var connectionResumeIntent: MobileWorkspaceConnectionResumeIntent

    init(
        descriptor: MobileWorkspaceDescriptor, hosts: any RemoteSessionHostStore,
        transfers: SFTPTransferCoordinator? = nil,
        sftpEdits: SFTPEditService? = nil,
        terminalSettings: TerminalSettingsModel = TerminalSettingsModel(),
        connectionServices: MobileWorkspaceConnectionServices = .live,
        reconnectController: SessionReconnectController = SessionReconnectController(),
        initialCommand: String? = nil,
        recordsInitialCommandInHistory: Bool = true,
        initialSFTPPath: String? = nil,
        transientHost: Host? = nil,
        connectionRoute: SSHConnectionRoute? = nil,
        usernameHint: String? = nil,
        connectionOrigin: RemoteConnectionOrigin = .library,
        advisoryTelnetPassword: SSHSecret? = nil,
        externalSFTPResourcePath: String? = nil,
        externalSFTPMustBeDirectory: Bool = false
    ) {
        self.terminalSettings = terminalSettings
        commandHistory = CommandHistoryModel(sessionID: descriptor.id)
        sftpHistory = SFTPHistoryModel(sessionID: descriptor.id)
        sftpChannel = MobileSFTPChannelModel(history: sftpHistory)
        self.transfers = transfers
        self.sftpEdits = sftpEdits
        self.descriptor = descriptor
        self.hosts = hosts
        self.transientHost = transientHost
        self.connectionRoute = connectionRoute
        self.usernameHint = usernameHint
        self.connectionOrigin = connectionOrigin
        self.advisoryTelnetPassword = advisoryTelnetPassword
        self.externalSFTPResourcePath = externalSFTPResourcePath
        self.externalSFTPMustBeDirectory = externalSFTPMustBeDirectory
        let artwork = HostIconCatalog.resolvedArtwork(for: hosts.host(descriptor.hostID) ?? transientHost)
        activitySession = WorkspaceActivityAttributes.Session(
            id: descriptor.id, title: descriptor.title, kind: descriptor.kind.rawValue,
            connected: false,
            iconAsset: artwork.assetName, iconSystemName: artwork.systemImageName)
        if connectionOrigin.allowsPersistence, hosts.host(descriptor.hostID) != nil {
            activitySession.recovery = .init(
                sourceWorkspaceID: descriptor.id, hostID: descriptor.hostID, kind: descriptor.kind.rawValue)
        }
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
                    await relay.owner?.receiveTerminalWrite(data)
                }
            },
            resize: { size in Task { @MainActor in await relay.owner?.resize(size) } },
            suppressesPixelOnlyResizes: true
        )
        terminal = TerminalViewState(configSource: .none)
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(backend), resizeThrottleMilliseconds: 35)
        let owner = surfaceOwner
        terminal.makePlatformView = { owner.view }
        relay.owner = self
        workingDirectoryObservation = terminal.$workingDirectory.sink { [weak relay] path in
            Task { @MainActor in
                relay?.owner?.receiveWorkingDirectory(path)
            }
        }
        commandObservation = TerminalCommandObservation(state: terminal, monitor: commandMonitor)
        surfaceOwner.bindFind(find)
        sessionPersistence.didChangePrompt = { [weak self] pending in
            if pending { self?.journey.waitForSessionSelection() } else { self?.journey.resume() }
        }
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
        guard authenticationRequired, let host = connectionHost(authenticationHostID ?? descriptor.hostID) else {
            return nil
        }
        if host.proxy != nil, authenticationIsProxy {
            let staged = proxySubmissions[host.id]
            return SSHAuthenticationPromptResolver.proxy(
                for: host, using: hosts, submission: staged,
                failureMessage: connectionFailure, mode: authenticationMode,
                allowsSaving: connectionOrigin.allowsPersistence)
        }
        let staged = submissions[host.id]
        return SSHAuthenticationPromptResolver.host(
            host, using: hosts, submission: staged, username: username,
            failureMessage: connectionFailure,
            mode: authenticationMode,
            allowsSaving: connectionOrigin.allowsPersistence)
    }

    private var authenticationIsProxy = false

    var hostKeyPrompt: SSHHostKeyPrompt? { connection.pendingHostKey }

    func submitAuthentication(
        identityID: UUID?, username: String, password: String?, passphrase: String?, keyID: UUID?, save: Bool
    ) {
        guard var host = connectionHost(authenticationHostID ?? descriptor.hostID) else { return }
        let identity = identityID.flatMap { hosts.identity($0) }
        let isProxy = authenticationPrompt?.isProxy == true
        let name = ((isProxy ? nil : identity?.username) ?? username)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if isProxy {
            let submission = SSHProxyAuthenticationSubmission(
                username: name, password: password, identityID: identity?.id)
            do {
                if save {
                    host = try hosts.saveProxyAuthentication(
                        submission, for: host, selectedIdentity: identity,
                        suppliedPassword: password)
                }
                proxySubmissions[host.id] = submission
            } catch {
                connectionFailure = error.localizedDescription
                authenticationPrompt = makeAuthenticationPrompt()
                return
            }
            authenticationRequired = false
            authenticationIsProxy = false
            authenticationPrompt = nil
            journey.resume()
            connect()
            return
        }
        if let prompt = authenticationPrompt, prompt.requiresPassphrase {
            do {
                submissions[host.id] = try hosts.passphraseSubmission(
                    for: prompt, existing: submissions[host.id], passphrase: passphrase, save: save)
            } catch {
                connectionFailure = error.localizedDescription
                authenticationPrompt?.failureMessage = error.localizedDescription
                return
            }
        } else if host.isTailscaleManaged {
            if save, !hosts.saveTailscaleUsername(name, hostID: host.id) {
                connectionFailure = TailscaleConfigurationError.unavailable.localizedDescription
                authenticationPrompt = makeAuthenticationPrompt()
                return
            }
            submissions[host.id] = SSHAuthenticationSubmission(username: name)
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
        if let host = connectionHost(descriptor.hostID) {
            do { try hosts.requireHostAccess(host) } catch {
                operationError = error.localizedDescription
                return
            }
        }
        _ = terminal.paste(text: text)
        terminal.requestFocus()
    }

    func generateCommand(
        using generator: any CommandGenerating,
        readViewport: @MainActor (MobileWorkspace) -> String? = { $0.readViewportText() }
    ) {
        if commandGeneration.isRunning {
            cancelCommandGeneration()
            return
        }
        guard descriptor.kind.isSSHTerminal, canGenerateFromCurrentDraft else {
            showCommandGenerationFailure(
                String(
                    localized:
                        AppStrings.Workspace.commandGeneratorShellRequirement
                )
            )
            return
        }
        guard let workingDirectory, !workingDirectory.isEmpty, let integratedShell else {
            showCommandGenerationFailure(
                String(localized: AppStrings.Workspace.theFocusedShellHasNotReportedItsCurrentDirectory)
            )
            return
        }

        // Capture before the shell draft request can redraw or scroll the terminal.
        let viewport = readViewport(self).map { CommandGeneratorContext.Viewport(text: $0) }
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
                    remoteSystemInfo: includesSystemInfo ? remoteSystemInfo : nil,
                    viewport: viewport
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
        guard !descriptor.kind.isSSHTerminal || isShellIntegrationEnabled else { return }
        guard !hasRuntimeContext else { return }
        let path = path?.isEmpty == false ? path : nil
        guard workingDirectory != path else { return }
        workingDirectory = path
        cancelPendingUpload()
        invalidateCommandGeneration()
    }

    var canGenerateFromCurrentDraft: Bool {
        connected && isShellIntegrationEnabled && shellIntegrationAvailable && isShellPromptReady
            && TerminalCommandDraftController.supportedShells.contains(integratedShell ?? "")
            && (!hasRuntimeContext || terminalContext.ticket(requiring: [.readDraft, .replaceDraft]) != nil)
    }

    func receiveInteractiveTerminalInput(_ data: Data) async {
        guard acceptsTerminalInput else { return }
        await receiveTerminalWrite(data)
    }

    private func receiveTerminalWrite(_ data: Data) async {
        // Native interaction is disabled under Journey; this callback also carries
        // protocol replies, which must still reach the existing transport.
        invalidateCommandGeneration()
        if descriptor.kind == .telnet {
            telnet?.write(data)
        } else if let ssh {
            terminalContext.noteInput()
            await connectionServices.writeSSH(ssh, data)
        }
    }

    private func writeSSHDirectly(_ data: Data) async {
        guard acceptsTerminalInput else { return }
        terminalContext.noteInput()
        guard let ssh else { return }
        await connectionServices.writeSSH(ssh, data)
    }

    private func requestCurrentDraft() async throws -> String {
        if hasRuntimeContext {
            guard let ticket = terminalContext.ticket(requiring: .readDraft),
                let context = terminalContext.active, let ssh
            else { throw TerminalDraftError.unavailable }
            let value = try await ssh.contextDraft(context)
            guard terminalContext.isCurrent(ticket, requiring: .readDraft) else {
                throw TerminalDraftError.unavailable
            }
            return value
        }
        return try await commandDraft.read(isAvailable: canGenerateFromCurrentDraft) { [weak self] data in
            await self?.writeSSHDirectly(data)
        }
    }

    private func replaceCurrentDraft(with command: String) async {
        if hasRuntimeContext {
            guard let ticket = terminalContext.ticket(requiring: .replaceDraft),
                let context = terminalContext.active, let ssh,
                terminalContext.isCurrent(ticket, requiring: .replaceDraft)
            else { return }
            do {
                _ = try await ssh.contextDraft(context, replacing: command)
            } catch {
                if terminalContext.isCurrent(ticket, requiring: .replaceDraft) {
                    receiveRuntimeContext(.init(status: .unknown))
                }
                showCommandGenerationFailure(TerminalDraftError.unavailable.localizedDescription)
            }
            return
        }
        await writeSSHDirectly(commandDraft.replacementPayload(for: command))
        terminal.requestFocus()
    }

    func validatedSameDirectoryLaunch(_ expected: MobileWorkspaceDirectoryLaunch) async
        -> MobileWorkspaceDirectoryLaunch?
    {
        guard sameDirectoryLaunch == expected else { return nil }
        do {
            if hasRuntimeContext, let context = terminalContext.active, let ssh {
                let generation = terminalContext.generation
                try await ssh.confirmContext(context)
                guard terminalContext.generation == generation, terminalContext.active == context else { return nil }
            } else {
                try await confirmDirectoryContext(terminalContext.ticket(requiring: .directory))
            }
            return sameDirectoryLaunch == expected ? expected : nil
        } catch {
            return nil
        }
    }

    private func confirmDirectoryContext(_ ticket: TerminalContextCoordinator.Ticket?) async throws {
        guard hasRuntimeContext else { return }
        guard let ticket, terminalContext.isCurrent(ticket, requiring: .directory),
            let context = terminalContext.active, let ssh
        else { throw TerminalDraftError.unavailable }
        do {
            try await ssh.confirmContext(context)
            guard terminalContext.isCurrent(ticket, requiring: .directory) else { throw TerminalDraftError.unavailable }
        } catch {
            if terminalContext.isCurrent(ticket, requiring: .directory) {
                receiveRuntimeContext(.init(status: .unknown))
            }
            throw error
        }
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
        terminalContext.reset()
        if hasRuntimeContext { commandHistory.selectContext(nil, generation: terminalContext.generation) }
        hasRuntimeContext = false
        contextHistory.removeAll()
        cancelCommandGeneration()
        integratedShell = nil
        remoteSystemInfo = nil
        isShellPromptReady = false
        shellIntegrationAvailable = false
        isInitialCommandSubmissionReady = false
        initialCommandStartupTicket = nil
        pendingConnectionStartupCommand = nil
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
        if case .ordinaryStartupUnavailable(let ticket) = event {
            guard sessionPersistence.attachment == nil else { return }
            guard let ticket else {
                pendingCommand = nil
                pendingConnectionStartupCommand = nil
                initialCommandStartupTicket = nil
                return
            }
            initialCommandStartupTicket = ticket
            isInitialCommandSubmissionReady = true
            submitPendingInitialCommandIfReady()
            return
        }
        if case .runtime(let update) = event {
            receiveRuntimeContext(update)
            return
        }
        guard !hasRuntimeContext else { return }
        commandMonitor.receiveShellEvent(event)
        switch event {
        case .runtime, .ordinaryStartupUnavailable: break
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
                activeHistoryID = commandHistory.record(command)?.id
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
                for: id, exitStatus: status, duration: duration)
            activeHistoryID = nil
        case .draft(let draft):
            commandDraft.receive(draft)
        }
    }

    private func receiveRuntimeContext(_ update: TerminalRuntimeUpdate) {
        hasRuntimeContext = true
        let previous = terminalContext.revision
        let events = terminalContext.receive(update, generation: terminalContext.generation)
        loadContextHistory()
        commandMonitor.receiveRuntimeEvents(events)
        if previous != terminalContext.revision {
            commandDraft.cancel()
            cancelPendingUpload()
            invalidateCommandGeneration()
        }
        workingDirectory = terminalContext.directory
        integratedShell = terminalContext.active?.shell
        shellIntegrationAvailable = terminalContext.active?.capabilities.contains(.commandLifecycle) == true
        isShellPromptReady = terminalContext.active?.promptReady == true
        for event in events {
            switch event.payload {
            case .commandStarted(let command):
                if command == commandExcludedFromHistory {
                    commandExcludedFromHistory = nil
                } else {
                    contextHistory[event.context] = commandHistory.record(command)?.id
                }
            case .commandFinished(let status, let duration):
                if let id = contextHistory.removeValue(forKey: event.context) {
                    commandHistory.recordCompletion(for: id, exitStatus: status, duration: duration)
                }
            case .draft(_, let value):
                if terminalContext.active?.identity == event.context { commandDraft.receive(value) }
            default: break
            }
        }
        if update.status == .ordinary, isShellPromptReady {
            isInitialCommandSubmissionReady = true
            submitPendingInitialCommandIfReady()
        }
    }

    private func loadContextHistory() {
        let context = terminalContext.active
        let source = commandHistory.selectContext(context, generation: terminalContext.generation)
        guard descriptor.kind == .ssh, let context, let source, let ssh, commandHistory.loadError == nil else {
            return
        }
        commandHistory.load(
            using: RemoteShellHistoryLoader(channel: ssh, charset: historyCharset, context: context), source: source)
    }

    private func restoreTransport() {
        guard !restoringTransport else { return }
        restoringTransport = true
        let token = generation
        attempt = Task { [weak self] in
            guard let self else { return }
            defer { restoringTransport = false }
            do {
                guard let host = connectionHost(descriptor.hostID), host.isEnabled(transport) else {
                    throw TerminalTransportError.invalidCheckpoint
                }
                let record = try await terminalRecoveryStore.record(recoveryID)
                let currentUsername =
                    host.isTailscaleManaged
                    ? hosts.savedTailscaleUsername(for: host) : hosts.identity(for: host)?.username
                guard record.transport == transport,
                    currentUsername == nil || currentUsername == record.username
                else { throw TerminalTransportError.invalidCheckpoint }
                try Task.checkCancellation()
                guard generation == token else { return }
                let checkpoint = try await terminalRecoveryStore.consume(recoveryID, host: host)
                try Task.checkCancellation()
                guard generation == token else { return }
                resumeCheckpoint = checkpoint
                resumeUsername = record.username
                requiresTransportRecovery = false
                pendingCommand = nil
                pendingConnectionStartupCommand = nil
                connect()
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                if sessionPersistence.attachment != nil {
                    do {
                        try await terminalRecoveryStore.discard(recoveryID)
                        guard generation == token, !Task.isCancelled else { return }
                        // tmux has its own server-side identity; validate it over a new transport,
                        // never replay the launch command or silently replace a missing session.
                        requiresTransportRecovery = false
                        resumeCheckpoint = nil
                        resumeUsername = nil
                        sessionPersistence.requiresSelection = true
                        pendingCommand = nil
                        pendingConnectionStartupCommand = nil
                        connect()
                        return
                    } catch {
                        guard generation == token, !Task.isCancelled else { return }
                    }
                }
                transportState = .failed
                connectionFailure = TerminalTransportError.invalidCheckpoint.localizedDescription
                status = connectionFailure ?? ""
                busy = false
                presentTransportRecovery(.failed, message: connectionFailure ?? "")
            }
        }
    }

    func connect() {
        if transportSuspension != nil {
            resumeAfterBackground()
            return
        }
        if requiresTransportRecovery {
            restoreTransport()
            return
        }
        if transport.isResumable, let ssh {
            Task { try? await ssh.retryTransport() }
            return
        }
        guard !busy, !connected else { return }
        if !descriptor.kind.isSSHTerminal, sessionPersistence.requiresSelection {
            busy = true
            presentConnectionJourney(mode: .connection)
            attempt = Task { [weak self] in
                guard let self else { return }
                do {
                    try await sessionPersistence.confirmPlainConnection()
                    busy = false
                    connect()
                } catch {
                    busy = false
                    status = String(localized: AppStrings.Connections.disconnected)
                }
            }
            return
        }
        cancelPendingUpload()
        stopSSHEventConsumer()
        let reconnecting = connection.isRecovering
        let token = UUID()
        generation = token
        transportState = nil
        commandMonitor.beginConnection()
        if descriptor.kind.isSSHTerminal { commandMonitor.requireScopedEvents() }
        activeHistoryID = nil
        resetCommandGeneratorShellState()
        operationError = nil
        busy = true
        connectionFailure = nil
        status = String(
            localized: reconnecting ? AppStrings.Connections.reconnecting : AppStrings.Connections.connecting)
        guard let host = connectionHost(descriptor.hostID) else {
            let message = String(localized: AppStrings.Connections.theHostIsNoLongerAvailable)
            connection.stopRecovery()
            connectionFailure = message
            status = String(localized: AppStrings.Connections.disconnected)
            busy = false
            journey.fail(message)
            return
        }
        guard host.isEnabled(transport) else {
            busy = false
            connectionFailure = TerminalTransportError.unsupportedRoute.localizedDescription
            journey.fail(connectionFailure ?? "")
            return
        }
        if descriptor.kind == .telnet {
            connectTelnet(host: host, token: token, reconnecting: reconnecting)
            return
        }
        isShellIntegrationEnabled =
            descriptor.kind != .mosh
            && host.shellIntegrationMode.isEnabled(
                globalSetting: terminalSettings.preferences.shellIntegration)
        if resumeCheckpoint == nil, descriptor.kind.isSSHTerminal, pendingCommand == nil,
            let snippetID = host.startupSnippetID,
            let body = hosts.snippet(snippetID)?.body,
            !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            pendingConnectionStartupCommand = MobilePendingInitialCommand(
                command: body, recordsInHistory: true
            )
        }
        let route = connectionRoute?.hosts ?? hosts.route(for: host)
        let authenticationRoute = resumeCheckpoint == nil ? route : (transport == .mosh ? [] : Array(route.dropLast()))
        journey.begin(
            host: host, route: route,
            purpose: connectionPurpose,
            username: usernameHint ?? hosts.identity(for: host)?.username,
            mode: reconnecting ? .reconnection : .connection)
        if resumeCheckpoint == nil, host.isTailscaleManaged, submissions[host.id] == nil, usernameHint == nil,
            hosts.savedTailscaleUsername(for: host) == nil
        {
            authenticationRequired = true
            authenticationIsProxy = false
            authenticationMode = .localIdentity
            authenticationHostID = host.id
            username = hosts.tailscaleUsername(for: host)
            authenticationPrompt = makeAuthenticationPrompt()
            journey.waitForTailscaleUsername(at: host.id)
            busy = false
            return
        }
        if let proxyHost = proxySubmissions.firstHostRequiringProxyPassword(in: authenticationRoute) {
            authenticationRequired = true
            authenticationIsProxy = true
            authenticationMode = .localIdentity
            authenticationHostID = proxyHost.id
            username = proxySubmissions[proxyHost.id]?.username ?? proxyHost.proxy?.username ?? ""
            authenticationPrompt = makeAuthenticationPrompt()
            journey.waitForProxyAuthentication(at: proxyHost.id)
            busy = false
            return
        }
        if let passwordHost = submissions.firstHostRequiringPassword(in: authenticationRoute) {
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
            in: authenticationRoute, key: hosts.key, requiresEntry: hosts.requiresPassphraseEntry
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
        var attemptSubmissions = submissions.takeAuthenticationSecrets()
        if let usernameHint, attemptSubmissions[host.id] == nil {
            attemptSubmissions[host.id] = SSHAuthenticationSubmission(username: usernameHint)
        }
        let attemptProxySubmissions = proxySubmissions.takeProxyAuthenticationSecrets()
        let progressHandler = connection.progressHandler(attemptID: token) { [weak self] in
            self?.generation == $0
        }
        connection.clearHostKeyPrompt()
        attempt = Task { [weak self, weak hosts] in
            guard let self, let hosts else { return }
            defer { if generation == token { busy = false } }
            guard generation == token, !Task.isCancelled else { return }
            do {
                try await hosts.resolveHostAccess(host)
                var resolvedConfiguration: SSHConnectionConfiguration
                if resumeCheckpoint != nil, transport == .mosh {
                    resolvedConfiguration = SSHConnectionConfiguration(
                        hostID: host.id, host: host.host, port: host.sshPort,
                        username: resumeUsername ?? "", credentials: [], expectedHostKeys: [])
                } else {
                    let preparation = try hosts.prepareSSHConnection(
                        for: host, submissions: attemptSubmissions,
                        proxySubmissions: attemptProxySubmissions,
                        temporaryHostKeys: temporaryKeys)
                    resolvedConfiguration = try await preparation.resolve(
                        discoveryOnly: resumeCheckpoint != nil, trustPolicy: .allowChallenge)
                }
                if resolvedConfiguration.accessHostIDs.isEmpty {
                    resolvedConfiguration.accessHostIDs = hosts.route(for: host).map(\.id)
                    resolvedConfiguration.accessCheck = hosts.connectionAccessCheck(
                        for: resolvedConfiguration.accessHostIDs)
                }
                resolvedConfiguration.beforeConnect = hosts.connectionWakeAction(
                    for: resolvedConfiguration.accessHostIDs)
                if let resumeUsername { resolvedConfiguration.username = resumeUsername }
                let config = resolvedConfiguration
                guard generation == token, !Task.isCancelled else { return }
                var request = SSHConnectionRequest(
                    configuration: config,
                    authorizeHostKey: { [weak self] challenge in
                        guard let self else { throw CancellationError() }
                        return await self.connection.authorizeHostKey(challenge)
                    },
                    keyboardInteractive: { [weak self] challenge in
                        guard let self, await self.generation == token else { throw CancellationError() }
                        return try await self.connection.answerKeyboardInteractive(challenge)
                    },
                    securityKeySigning: { [weak self] request in
                        guard let self, await self.generation == token else { throw CancellationError() }
                        return try await self.connection.signWithSecurityKey(request)
                    },
                    hostKeyConstraints: connectionOrigin.hostKeyConstraints
                )

                request.agentForwardingContextID = id
                var externalFile: RemoteFile?
                if descriptor.kind.isSSHTerminal {
                    let backend = backend
                    let handlers = startSSHEventConsumer(for: token)
                    let session = connectionServices.makePTYChannel(
                        { backend.receive($0) },
                        handlers.exit,
                        handlers.shellIntegration)
                    ssh = session
                    historyCharset = host.charset
                    if transport.isResumable {
                        recoveryRecord = TerminalRecoveryRecord(
                            id: recoveryID, host: host, username: config.username, transport: transport)
                        recoveryLease = await terminalRecoveryStore.register(recoveryID)
                        guard generation == token else { throw CancellationError() }
                        let snapshot = hosts.additionalConnectionSnapshot(from: config)
                        let port = host.terminalTransports.eternalTerminalPort
                        let hostKeyAuthorizer = request.authorizeHostKey
                        let keyboardInteractive = request.keyboardInteractive
                        let securityKeySigning = request.securityKeySigning
                        let hostKeyConstraints = request.hostKeyConstraints
                        let needsControlRoute = transport == .mosh && resumeCheckpoint != nil
                        let controlUsername = config.username
                        let requestFactory: @Sendable (Bool) async throws -> SSHConnectionRequest = {
                            [weak self, weak hosts] authenticatingTarget in
                            guard let self, let hosts, await self.generation == token else {
                                throw CancellationError()
                            }
                            let selectedSnapshot =
                                if authenticatingTarget && needsControlRoute {
                                    try await hosts.resumableControlSnapshot(for: host, username: controlUsername)
                                } else {
                                    snapshot
                                }
                            return try await hosts.resumableRouteRequest(
                                from: selectedSnapshot, authorizeHostKey: hostKeyAuthorizer,
                                keyboardInteractive: keyboardInteractive, securityKeySigning: securityKeySigning,
                                hostKeyConstraints: hostKeyConstraints, authenticatingTarget: authenticatingTarget)
                        }
                        await session.configureTransport(
                            transport, options: host.terminalTransports, checkpoint: resumeCheckpoint,
                            route: {
                                try await TerminalTransportRoute.open(using: requestFactory(false), port: port)
                            },
                            control: { command in
                                try await TerminalTransportRoute.execute(command, using: requestFactory(true))
                            },
                            stateChanged: { [weak self] state in
                                Task { @MainActor in
                                    guard let self, self.generation == token else { return }
                                    self.receiveTransportState(state)
                                }
                            })
                    }
                    await session.configureEnvironment(host.environmentVariables) { variables in
                        let list = variables.joined(separator: ", ")
                        let warning = String(localized: AppStrings.Terminal.rejectedEnvironmentVariables(list))
                        backend.receive(Data("\r\n⚠︎ \(warning)\r\n".utf8))
                    }
                    let persistence = sessionPersistence
                    let explicit = pendingCommand?.command
                    let startup = explicit ?? pendingConnectionStartupCommand?.command
                    let integration = isShellIntegrationEnabled
                    if host.sessionPersistence.enabled || persistence.attachment != nil || persistence.requiresSelection
                    {
                        persistence.didChangeAttachment = { [weak self] reference in
                            guard let self, self.generation == token else { return }
                            if reference != nil {
                                self.pendingCommand = nil
                                self.pendingConnectionStartupCommand = nil
                            }
                            self.activitySession.recovery?.remoteSession = reference.flatMap {
                                try? JSONEncoder().encode($0)
                            }
                            self.didChangeState?(self.activitySession)
                        }
                        await session.configureStartup { execute in
                            try await persistence.prepare(
                                preferences: host.sessionPersistence, registry: .live, execute: execute,
                                hostID: host.id, endpoint: "\(host.host):\(host.sshPort)", username: config.username,
                                startupCommand: startup, requiresNewSession: explicit != nil,
                                shellIntegration: integration, environment: host.environmentVariables)
                        }
                    }
                    try await connectionServices.connectSSH(
                        session,
                        request,
                        isShellIntegrationEnabled,
                        UInt16(clamping: viewport.columns),
                        UInt16(clamping: viewport.rows),
                        progressHandler
                    )
                    if resumeCheckpoint != nil {
                        pendingCommand = nil
                        pendingConnectionStartupCommand = nil
                        resumeCheckpoint = nil
                    }
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
                    let homeDirectoryResult: Result<String, any Error>
                    do {
                        homeDirectoryResult = .success(try await client.homeDirectory())
                    } catch {
                        homeDirectoryResult = .failure(error)
                    }
                    guard generation == token, !Task.isCancelled else { return }
                    let initialPath: String
                    if reconnecting {
                        initialPath = sftpChannel.path
                    } else if let requested = externalSFTPResourcePath {
                        let resolved: String
                        if requested == "/~" || requested.hasPrefix("/~/") {
                            let home = RemotePath.normalized(try homeDirectoryResult.get())
                            resolved = requested == "/~" ? home : RemotePath.join(home, String(requested.dropFirst(3)))
                        } else {
                            resolved = RemotePath.normalized(requested)
                        }
                        guard let resource = try await client.attributes(at: resolved) else {
                            throw SFTPError.operation(
                                String(localized: AppStrings.SFTP.theRemoteFileIsNoLongerAvailable))
                        }
                        if resource.isDirectory {
                            initialPath = resource.path
                        } else {
                            guard !externalSFTPMustBeDirectory else {
                                throw SFTPError.operation(
                                    String(localized: AppStrings.SFTP.theSftpLinkRequiresADirectoryButItsPathIsAFile))
                            }
                            initialPath = RemotePath.parent(of: resource.path)
                            externalFile = resource
                        }
                        externalSFTPResourcePath = nil
                    } else if let pendingInitialSFTPPath {
                        initialPath = pendingInitialSFTPPath
                    } else if host.sftpChannelInitialPath.isEmpty {
                        initialPath = try homeDirectoryResult.get()
                    } else {
                        initialPath = host.sftpChannelInitialPath
                    }
                    try await sftpChannel.attach(
                        fileSystem: client,
                        path: initialPath,
                        homeDirectory: try? homeDirectoryResult.get(),
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
                guard generation == token, !Task.isCancelled, transportState != .ended else { return }
                if transportState == .recovering || transportState == .suspended || transportState == .failed { return }
                let additionalSnapshot = hosts.additionalConnectionSnapshot(from: config)
                transferSnapshot = additionalSnapshot
                if let sftp {
                    transferContext = SFTPTransferContext(
                        snapshot: additionalSnapshot, hostStore: hosts, channel: sftp)
                }
                submissions.removeAll()
                proxySubmissions.removeAll()
                let wasReconnecting = connection.markConnected()
                connected = true
                if descriptor.kind == .ssh, let ssh {
                    if hasRuntimeContext, terminalContext.active?.historySource != nil {
                        loadContextHistory()
                    } else {
                        commandHistory.load(
                            using: RemoteShellHistoryLoader(channel: ssh, charset: host.charset), source: nil)
                    }
                }
                status = String(localized: AppStrings.Connections.connected)
                if journey.phase != .succeeded { journey.succeed() }
                if sessionPersistence.attachment != nil {
                    pendingCommand = nil
                    pendingConnectionStartupCommand = nil
                }
                if wasReconnecting, descriptor.kind == .ssh, sessionPersistence.attachment == nil {
                    appendTerminalNotice(String(localized: AppStrings.Terminal.reconnectedANewRemoteShellHasStarted))
                }
                if descriptor.kind.isSSHTerminal {
                    if !isShellIntegrationEnabled {
                        isInitialCommandSubmissionReady = true
                    }
                    submitPendingInitialCommandIfReady()
                } else if let externalFile {
                    _ = preview(externalFile) { [weak self] url in
                        self?.pendingExternalPreviewURL = url
                    }
                }
            } catch {
                guard generation == token else { return }
                if resumeCheckpoint != nil, ssh != nil {
                    // Once a restored engine could have transmitted, never reuse its saved counters.
                    resumeCheckpoint = nil
                    requiresTransportRecovery = true
                    transportState = .failed
                }
                stopSSHEventConsumer()
                connectionFailure =
                    error is CancellationError
                    ? String(localized: AppStrings.Connections.connectionCancelled) : error.localizedDescription
                let managedSFTPFailure =
                    host.isTailscaleManaged && descriptor.kind == .sftp
                    && !(error is CancellationError)
                if managedSFTPFailure {
                    connectionFailure = String(
                        localized: AppStrings.Tailscale.sftpFailure(
                            username: submissions[host.id]?.username ?? usernameHint
                                ?? hosts.tailscaleUsername(for: host),
                            address: host.host, detail: error.localizedDescription))
                    authenticationRequired = false
                    authenticationPrompt = nil
                }
                var requiresUserInteraction = false
                var preventsAutomaticReconnect =
                    error is CancellationError || managedSFTPFailure || transport.isResumable
                if let sshError = error as? TermindSSHError, !managedSFTPFailure {
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
                        authenticationIsProxy = sshError.isProxyAuthentication
                        if let endpoint = connectionHost(authenticationHostID ?? descriptor.hostID) {
                            username =
                                authenticationIsProxy
                                ? (proxySubmissions[endpoint.id]?.username ?? endpoint.proxy?.username ?? "")
                                : (submissions[endpoint.id]?.username ?? hosts.identity(for: endpoint)?.username ?? "")
                        }
                        authenticationPrompt = makeAuthenticationPrompt()
                        if authenticationIsProxy {
                            journey.waitForProxyAuthentication(
                                at: authenticationHostID ?? descriptor.hostID,
                                failure: error.localizedDescription)
                        } else if authenticationPrompt?.usernameOnly == true {
                            journey.waitForTailscaleUsername(
                                at: authenticationHostID ?? descriptor.hostID, failure: error.localizedDescription)
                        } else if authenticationPrompt?.requiresPassphrase == true {
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
                    if requiresTransportRecovery, transport.isResumable {
                        connection.stopRecovery()
                        presentTransportRecovery(.failed, message: connectionFailure ?? error.localizedDescription)
                    } else if (connection.hasConnectedOnce || reconnecting) && !preventsAutomaticReconnect {
                        scheduleReconnect(after: error.localizedDescription)
                    } else {
                        connection.stopRecovery()
                        journey.fail(connectionFailure ?? error.localizedDescription)
                        status = String(localized: AppStrings.Connections.disconnected)
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

    private func connectTelnet(host: Host, token: UUID, reconnecting: Bool) {
        guard host.telnetEnabled else {
            busy = false
            let message = String(localized: AppStrings.Connections.telnetIsDisabledForThisHost)
            connectionFailure = message
            status = String(localized: AppStrings.Connections.disconnected)
            journey.fail(message)
            return
        }
        journey.beginTelnet(
            host: host,
            username: usernameHint ?? hosts.identity(for: host, protocol: .telnet)?.username,
            mode: reconnecting ? .reconnection : .connection)
        let terminalBackend = backend
        let session = TelnetConnection(
            output: { data in terminalBackend.receive(data) },
            event: { [weak self] event in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.journey.receive(event)
                    if case .connected = event {
                        _ = self.connection.markConnected()
                        self.connected = true
                        self.busy = false
                        self.status = String(localized: AppStrings.Connections.connected)
                        self.journey.succeed()
                    }
                }
            },
            closed: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.telnet = nil
                    let message = message ?? String(localized: AppStrings.Terminal.theTelnetConnectionClosed)
                    if self.connection.hasConnectedOnce {
                        self.handleConnectionFailure(message)
                    } else {
                        self.busy = false
                        self.connected = false
                        self.status = String(localized: AppStrings.Connections.disconnected)
                        self.journey.fail(message)
                    }
                }
            })
        telnet?.disconnect()
        telnet = session
        attempt = Task { [weak self, weak hosts] in
            guard let self, let hosts else { return }
            do {
                try await hosts.resolveHostAccess(host)
                var configuration = try hosts.telnetConnectionConfiguration(for: host)
                if let usernameHint { configuration.username = usernameHint }
                if let password = self.advisoryTelnetPassword {
                    configuration.password = password
                    self.advisoryTelnetPassword = nil
                }
                try await session.connect(
                    using: configuration,
                    columns: UInt16(clamping: viewport.columns),
                    rows: UInt16(clamping: viewport.rows))
            } catch is CancellationError {
                guard generation == token else { return }
                busy = false
                status = String(localized: AppStrings.Connections.disconnected)
            } catch {
                guard generation == token else { return }
                telnet = nil
                busy = false
                connectionFailure = error.localizedDescription
                status = String(localized: AppStrings.Connections.disconnected)
                journey.fail(error.localizedDescription)
            }
        }
    }

    /// Consumes the explicit launch command once, then the Startup Snippet that
    /// was freshly resolved for this physical terminal shell.
    func consumePendingInitialCommand() -> String? {
        let command: MobilePendingInitialCommand
        if let explicit = pendingCommand {
            command = explicit
            pendingCommand = nil
        } else if let startup = pendingConnectionStartupCommand {
            command = startup
            pendingConnectionStartupCommand = nil
        } else {
            return nil
        }
        if !command.recordsInHistory {
            commandExcludedFromHistory = CommandHistoryEntry.normalizingLineContinuations(
                in: command.command
            )
        }
        return command.command
    }

    private func submitPendingInitialCommandIfReady() {
        guard descriptor.kind.isSSHTerminal, connected, isInitialCommandSubmissionReady,
            let session = ssh, let command = consumePendingInitialCommand()
        else { return }
        let token = generation
        let data = Data((command + "\r").utf8)
        let startupTicket = initialCommandStartupTicket
        initialCommandStartupTicket = nil
        Task { [weak self] in
            guard let self, generation == token, connected, ssh === session else { return }
            if let startupTicket {
                await connectionServices.submitInitialCommand(session, data, startupTicket)
            } else {
                await connectionServices.writeSSH(session, data)
            }
        }
    }

    func retryReconnectNow() {
        if transportSuspension != nil {
            resumeAfterBackground()
            return
        }
        if transport.isResumable {
            guard transportState == .recovering, let ssh else { return }
            let token = generation
            Task { [weak self] in
                do {
                    try await ssh.retryTransport()
                } catch {
                    guard let self, self.generation == token else { return }
                    self.receiveTransportState(.failed, failure: error.localizedDescription)
                }
            }
            return
        }
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
        let oldTelnet = telnet
        let oldSFTP = sftp
        let oldTransferContext = transferContext
        transferContext = nil
        ssh = nil
        telnet = nil
        sftp = nil
        sftpChannel.detach()
        busy = false
        connected = false
        transferSnapshot = nil
        status = String(localized: AppStrings.Connections.disconnected)
        connectionFailure = reconnectState.lastError
        journey.fail(reconnectState.lastError)
        Task {
            await oldSSH?.disconnect()
            oldTelnet?.disconnect()
            if let oldTransferContext { await oldTransferContext.retire() } else { await oldSFTP?.disconnect() }
        }
    }

    func suspendForBackgroundExpiration() {
        if transport.isResumable, ssh != nil {
            suspendResumableTransport()
            return
        }
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
        let oldTelnet = telnet
        let oldSFTP = sftp
        let oldTransferContext = transferContext
        transferContext = nil
        ssh = nil
        telnet = nil
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
        proxySubmissions.removeAll()
        connectionFailure = nil
        operationError = nil
        connection.suspendForForegroundResume(reconnecting: reconnecting)
        status = String(
            localized: reconnecting ? AppStrings.Connections.reconnecting : AppStrings.Connections.connecting)
        presentConnectionJourney(mode: reconnecting ? .reconnection : .connection)
        Task {
            await oldSSH?.disconnect()
            oldTelnet?.disconnect()
            if let oldTransferContext { await oldTransferContext.retire() } else { await oldSFTP?.disconnect() }
        }
    }

    func resumeAfterBackground() {
        guard connectionResumeIntent == .foreground else { return }
        connectionResumeIntent = .none
        if transport.isResumable, let ssh {
            let token = generation
            let suspension = transportSuspension
            Task { [weak self] in
                await suspension?.value
                guard let self, self.generation == token else { return }
                do {
                    try await self.terminalRecoveryStore.invalidate(self.recoveryID)
                    guard self.generation == token else { return }
                    try await ssh.resumeTransport()
                    self.transportSuspension = nil
                } catch {
                    guard self.generation == token else { return }
                    self.receiveTransportState(.failed, failure: error.localizedDescription)
                }
            }
            return
        }
        connect()
    }

    func suspendResumableTransport() {
        guard transport.isResumable, transportSuspension == nil, let ssh,
            let record = recoveryRecord, let lease = recoveryLease
        else { return }
        connectionResumeIntent = .foreground
        let token = generation
        transportSuspension = Task { [weak self] in
            do {
                let checkpoint = try await ssh.suspendTransport()
                guard let self, self.generation == token, self.ssh === ssh else { return }
                try await self.terminalRecoveryStore.save(record, checkpoint: checkpoint, lease: lease)
            } catch {
                guard let self, self.generation == token else { return }
                self.operationError = error.localizedDescription
            }
        }
    }

    func receiveTransportState(_ state: ResumableTerminalState, failure: String? = nil) {
        guard transportState != .ended, transportState != .closed else { return }
        guard state != transportState || failure != nil else { return }
        transportState = state
        switch state {
        case .connected:
            connected = true
            busy = false
            status = String(localized: AppStrings.Connections.connected)
            if journey.transportRecovery != nil {
                _ = connection.markConnected()
                connectionFailure = nil
                journey.succeed()
            }
        case .recovering, .suspended:
            connected = false
            status = String(localized: AppStrings.Connections.reconnecting)
            presentTransportRecovery(
                state == .recovering ? .recovering : .suspended,
                message: String(
                    localized: state == .recovering
                        ? AppStrings.Transports.recoveringSession : AppStrings.Transports.sessionSuspended))
        case .ended:
            connected = false
            busy = false
            connectionResumeIntent = .none
            recoveryLease = nil
            transportSuspension?.cancel()
            transportSuspension = nil
            let recoveryID = recoveryID
            Task { [terminalRecoveryStore] in try? await terminalRecoveryStore.discard(recoveryID) }
            handleRemoteExit(.success(0))
        case .failed:
            let initialConnection =
                !connection.hasConnectedOnce && resumeCheckpoint == nil && !requiresTransportRecovery
                && journey.mode == .connection && journey.isPresented && journey.transportRecovery == nil
            connected = false
            busy = false
            connection.resetRecovery()
            connectionFailure = failure ?? TerminalTransportError.sessionFailed.localizedDescription
            status = connectionFailure ?? ""
            if initialConnection {
                journey.fail(connectionFailure ?? "")
            } else {
                presentTransportRecovery(.failed, message: connectionFailure ?? "")
            }
            let recoveryID = recoveryID
            Task { [terminalRecoveryStore] in try? await terminalRecoveryStore.discard(recoveryID) }
        // Transport cleanup can follow a failure; the workspace owns dismissing its Journey.
        case .connecting, .closed: break
        }
    }

    private func presentTransportRecovery(_ state: ConnectionJourney.TransportRecovery, message: String) {
        if journey.endpoints.isEmpty {
            let host =
                connectionHost(descriptor.hostID)
                ?? Host(id: descriptor.hostID, name: descriptor.title, host: descriptor.title)
            journey.begin(
                host: host, route: connectionRoute?.hosts ?? hosts.route(for: host), purpose: connectionPurpose,
                username: resumeUsername ?? connectionRoute?.usernames[host.id] ?? usernameHint,
                mode: .reconnection)
        }
        journey.updateTransportRecovery(state, message: message)
    }

    func restoreRemoteSession(_ reference: RemoteSessionReference?) {
        sessionPersistence.attachment = reference
        activitySession.recovery?.remoteSession = reference.flatMap { try? JSONEncoder().encode($0) }
        didChangeState?(activitySession)
    }

    func terminatePersistentSession(
        _ reference: RemoteSessionReference, isCurrentOwner: @MainActor () -> Bool = { true }
    ) async throws {
        guard sessionPersistence.attachment == reference, let channel = ssh else {
            throw RemoteSessionFailure.sessionMissing
        }
        try await channel.releaseTerminalForControl()
        connected = false
        resetCommandGeneratorShellState()
        status = String(localized: AppStrings.Connections.disconnected)
        let execute = try await channel.sessionCommandExecutor()
        let backend = try RemoteSessionBackendRegistry.live.backend(reference.backend, execute: execute)
        let sessions = try await backend.sessions()
        guard isCurrentOwner(), ssh === channel, sessionPersistence.attachment == reference else {
            throw CancellationError()
        }
        guard sessions.contains(where: { backend.matches(reference, session: $0) }) else {
            throw RemoteSessionFailure.ownershipMismatch
        }
        try await backend.terminate(reference)
        if sessionPersistence.attachment == reference { sessionPersistence.markEnded() }
        connected = false
        status = String(localized: AppStrings.SessionPersistence.ended)
    }

    private func handleRemoteExit(_ result: Result<Int32, TermindSSHError>) {
        cancelPendingUpload()
        resetCommandGeneratorShellState()
        if case .success(let exitCode) = result, let reference = sessionPersistence.attachment, let channel = ssh {
            let attemptID = generation
            Task { [weak self] in
                guard let self else { return }
                var sessionExists: Bool?
                do {
                    let execute = try await channel.sessionCommandExecutor()
                    let backend = try RemoteSessionBackendRegistry.live.backend(reference.backend, execute: execute)
                    let sessions = try await backend.sessions()
                    sessionExists = sessions.contains(where: { backend.matches(reference, session: $0) })
                } catch {
                    // An unverified exit must not erase identity or start a replacement session.
                }
                guard self.generation == attemptID, self.sessionPersistence.attachment == reference else { return }
                let shouldClose = self.sessionPersistence.finishExit(exitCode: exitCode, sessionExists: sessionExists)
                await channel.disconnect()
                guard self.generation == attemptID else { return }
                self.ssh = nil
                self.connection.resetRecovery()
                self.connected = false
                self.busy = false
                self.connectionResumeIntent = .none
                if shouldClose {
                    self.didRequestClose?(self.id)
                    return
                }
                self.status = String(
                    localized: exitCode != 0
                        ? AppStrings.SessionPersistence.failed
                        : self.sessionPersistence.detached
                            ? AppStrings.SessionPersistence.detached : AppStrings.SessionPersistence.ended)
            }
            return
        }

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
            status = String(localized: AppStrings.Connections.disconnected)
            didRequestClose?(id)
        case .failure(let failure):
            handleConnectionFailure(failure.localizedDescription)
        }
    }

    private func handleConnectionFailure(_ message: String) {
        if transport.isResumable {
            receiveTransportState(.failed, failure: message)
            return
        }
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
        let oldTelnet = telnet
        let oldSFTP = sftp
        let oldTransferContext = transferContext
        transferContext = nil
        ssh = nil
        telnet = nil
        sftp = nil
        sftpChannel.detach()
        busy = false
        connected = false
        transferSnapshot = nil
        status = String(localized: AppStrings.Connections.reconnecting)
        if announcesLoss, descriptor.kind.isSSHTerminal {
            appendTerminalNotice(String(localized: AppStrings.Connections.connectionLostReconnectingProgress))
        }
        if let host = connectionHost(descriptor.hostID) {
            if descriptor.kind == .telnet {
                journey.beginTelnet(
                    host: host,
                    username: usernameHint ?? hosts.identity(for: host, protocol: .telnet)?.username,
                    mode: .reconnection)
            } else {
                journey.begin(
                    host: host, route: connectionRoute?.hosts ?? hosts.route(for: host),
                    purpose: connectionPurpose,
                    username: usernameHint ?? hosts.identity(for: host)?.username, mode: .reconnection)
            }
        }
        Task {
            await oldSSH?.disconnect()
            oldTelnet?.disconnect()
            if let oldTransferContext { await oldTransferContext.retire() } else { await oldSFTP?.disconnect() }
        }
    }

    private func appendTerminalNotice(_ message: String) {
        backend.receive(Data("\r\n\u{001B}[2m[Termind] \(message)\u{001B}[0m\r\n".utf8))
    }

    func trustHostKey(remember: Bool = true) {
        guard let observation = connection.pendingHostKey?.observation else { return }
        if remember, connectionOrigin.allowsPersistence {
            connection.trustHostKey(observation, using: hosts)
        } else {
            guard connection.useTemporaryHostKey(observation) else { return }
        }
    }

    func close() {
        bellObservation = nil
        commandHistory.close()
        sftpHistory.close()
        disconnect()
    }

    /// Connection intent only: closed runtimes, entered credentials and one-shot commands are not retained.
    struct ReopenState {
        let descriptor: MobileWorkspaceDescriptor
        var transientHost: Host? = nil
        var connectionRoute: SSHConnectionRoute? = nil
        var usernameHint: String? = nil
        var connectionOrigin: RemoteConnectionOrigin = .library
        var externalSFTPResourcePath: String? = nil
        var externalSFTPMustBeDirectory = false
    }

    var reopenState: ReopenState {
        ReopenState(
            descriptor: restorationDescriptor, transientHost: transientHost, connectionRoute: connectionRoute,
            usernameHint: usernameHint, connectionOrigin: connectionOrigin,
            externalSFTPResourcePath: externalSFTPResourcePath,
            externalSFTPMustBeDirectory: externalSFTPMustBeDirectory)
    }

    func disconnect() {
        if transport.isResumable {
            transportState = .closed
            let recoveryID = recoveryID
            Task { [terminalRecoveryStore] in try? await terminalRecoveryStore.discard(recoveryID) }
            recoveryLease = nil
            transportSuspension?.cancel()
            transportSuspension = nil
        }
        sessionPersistence.cancel()
        commandHistory.cancelLoading()
        commandMonitor.endConnection()
        cancelPendingUpload()
        stopSSHEventConsumer()
        resetCommandGeneratorShellState()
        connectionResumeIntent = .none
        connection.disconnect()
        advisoryTelnetPassword?.clear()
        advisoryTelnetPassword = nil
        connectionFailure = nil
        operationError = nil
        authenticationRequired = false
        authenticationPrompt = nil
        submissions.removeAll()
        proxySubmissions.removeAll()

        activeHistoryID = nil
        pendingCommand = nil
        pendingConnectionStartupCommand = nil
        pendingInitialSFTPPath = nil
        commandExcludedFromHistory = nil
        generation = UUID()
        attempt?.cancel()
        attempt = nil
        transferSnapshot = nil
        let oldSSH = ssh
        let oldTelnet = telnet
        let oldSFTP = sftp
        let oldTransferContext = transferContext
        transferContext = nil
        ssh = nil
        telnet = nil
        sftp = nil
        sftpChannel.detach()
        Task {
            await oldSSH?.disconnect()
            oldTelnet?.disconnect()
            if let oldTransferContext { await oldTransferContext.releaseOwner() } else { await oldSFTP?.disconnect() }
        }
        busy = false
        connected = false
        status = String(localized: AppStrings.Connections.disconnected)
    }

    func consumePendingExternalPreviewURL() -> URL? {
        defer { pendingExternalPreviewURL = nil }
        return pendingExternalPreviewURL
    }

    private func connectionHost(_ id: Host.ID) -> Host? {
        connectionRoute?.host(id) ?? hosts.host(id) ?? (id == descriptor.hostID ? transientHost : nil)
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
        refreshHostArtwork()
    }

    func refreshHostArtwork() {
        let savedHost = hosts.host(descriptor.hostID)
        let host = savedHost ?? transientHost
        let distribution: DetectedDistribution?
        if let savedHost {
            distribution = savedHost.detectedDistribution
        } else if case .resolved(let detected) = remoteSystemInfo?.distributionDetection {
            distribution = detected
        } else {
            distribution = host?.detectedDistribution
        }
        let artwork = HostIconCatalog.bundled.resolvedArtwork(
            overrideID: host?.iconOverrideID, distribution: distribution)
        guard
            activitySession.iconAsset != artwork.assetName || activitySession.iconSystemName != artwork.systemImageName
        else { return }
        activitySession.iconAsset = artwork.assetName
        activitySession.iconSystemName = artwork.systemImageName
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
            journey.fail(String(localized: AppStrings.Connections.theHostIsNoLongerAvailable))
            return
        }
        journey.begin(
            host: host, route: hosts.route(for: host),
            purpose: connectionPurpose,
            username: hosts.identity(for: host)?.username, mode: mode)
    }

    @discardableResult
    func prepareUpload(_ urls: [URL], insertPaths: Bool = false) -> Bool {
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { return false }
        cancelPendingUpload()
        guard transfers != nil, let snapshot = transferSnapshot,
            let destination = uploadDestination
        else {
            showUploadNotice(
                .rejected(
                    uploadTargetProblem
                        ?? String(localized: AppStrings.SFTP.theUploadDestinationIsUnavailable)
                )
            )
            return false
        }

        let connectionGeneration = generation
        let preparationID = UUID()
        let contextTicket = terminalContext.ticket(requiring: .directory)
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
                try await confirmDirectoryContext(contextTicket)
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
                let homeDirectory: String?
                if descriptor.kind == .sftp {
                    homeDirectory = sftpChannel.homeDirectory
                } else {
                    let proposed = try? await client.homeDirectory()
                    homeDirectory = proposed.flatMap { $0.hasPrefix("/") ? RemotePath.normalized($0) : nil }
                }
                try Task.checkCancellation()
                guard uploadPreparationID == preparationID,
                    generation == connectionGeneration, uploadDestination == destination
                else { throw CancellationError() }
                let batch = try await SFTPLocalUploadPlanner.prepare(
                    urls,
                    destination: destination,
                    client: client
                )
                try await confirmDirectoryContext(contextTicket)
                try Task.checkCancellation()
                guard uploadPreparationID == preparationID,
                    generation == connectionGeneration, uploadDestination == destination
                else {
                    throw CancellationError()
                }
                guard !batch.isEmpty else {
                    throw SFTPError.localFile(String(localized: AppStrings.SFTP.noUploadableFilesWereFound))
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
                    homeDirectory: homeDirectory,
                    client: client,
                    ownsClient: ownsClient,
                    context: context,
                    connectionGeneration: connectionGeneration,
                    insertPaths: insertPaths, terminalContext: contextTicket
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
            files: [file],
            homeDirectory: sftpChannel.homeDirectory
        )
    }

    func prepareRemoteCopy(_ payload: SFTPRemoteItemsPayload) {
        guard let transfers, transferSnapshot != nil,
            let sftp, connected
        else {
            operationError = String(localized: AppStrings.SFTP.theSftpConnectionIsNotAvailable)
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
            operationError = String(localized: AppStrings.SFTP.theSftpConnectionIsNotAvailable)
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
                        destinationHomeDirectory: sftpChannel.homeDirectory,
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
                    homeDirectory: sftpChannel.homeDirectory,
                    coordinator: transfers
                ) { [sftpHistory] path, state in
                    guard state == .completed else { return }
                    sftpHistory.record(kind: .file, path: path)
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
                try await confirmDirectoryContext(pendingUpload.terminalContext)
                let result = try await SFTPLocalUploadPlanner.enqueue(
                    pendingUpload.batch,
                    policy: policy,
                    hostID: descriptor.hostID,
                    connection: .context(pendingUpload.context),
                    homeDirectory: pendingUpload.homeDirectory,
                    client: pendingUpload.client,
                    coordinator: transfers,
                    uploadedPaths: pendingUpload.insertPaths
                        ? { [weak self] paths in
                            guard let self, self.connected,
                                self.generation == pendingUpload.connectionGeneration
                            else { return }
                            let text = paths.map(RemoteShellCommand.escapeArgument).joined(separator: " ") + " "
                            if self.hasRuntimeContext {
                                guard let ticket = pendingUpload.terminalContext,
                                    self.terminalContext.isCurrent(ticket, requiring: .directory)
                                else { return }
                                Task {
                                    guard self.terminalContext.isCurrent(ticket, requiring: .directory) else { return }
                                    await self.replaceCurrentDraft(with: text)
                                }
                            } else {
                                _ = self.terminal.paste(text: text)
                            }
                        } : nil
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
        if descriptor.kind.isSSHTerminal {
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
                        file, hostID: descriptor.hostID, connection: .context(transferContext), client: sftp,
                        homeDirectory: sftpChannel.homeDirectory)
                    sftpHistory.record(kind: .file, path: file.path)
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
                connection: .context(transferContext), scopedRoot: directory, overwrite: false,
                homeDirectory: sftpChannel.homeDirectory
            ) { [sftpHistory, path = file.path] state in
                guard state == .completed else { return }
                sftpHistory.record(kind: .file, path: path)
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
        return await sftpEdits.upload(
            id, connection: .context(transferContext), client: sftp,
            homeDirectory: sftpChannel.homeDirectory, replacing: replacing
        ) {
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
            operationError = String(localized: AppStrings.SFTP.theSftpConnectionIsNotAvailable)
            return false
        }
        let connectionGeneration = generation
        do {
            let file = try await sftp.attributes(at: path)
            guard generation == connectionGeneration, connected else { return false }
            guard let file, !file.isDirectory else {
                operationError = String(localized: AppStrings.SFTP.theRemoteFileIsNoLongerAvailable)
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
        if descriptor.kind == .telnet {
            telnet?.resize(
                columns: UInt16(clamping: size.columns), rows: UInt16(clamping: size.rows))
            return
        }
        await ssh?.resize(
            columns: UInt16(clamping: size.columns), rows: UInt16(clamping: size.rows),
            widthPixels: UInt32(clamping: size.widthPixels), heightPixels: UInt32(clamping: size.heightPixels))
    }
}

@MainActor
private final class MobileTerminalRelay {
    weak var owner: MobileWorkspace?
}
