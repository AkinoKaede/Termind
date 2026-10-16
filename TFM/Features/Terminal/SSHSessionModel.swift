import AppKit
import Combine
import Foundation
import GhosttyTerminal
import GhosttyTheme
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

import struct TermindDomain.Host

/// Workspace-owned routing for terminal input and shell completion.
/// Class-bound so a sshSession can keep the relationship weak while panes move
/// between Workspaces.
protocol SSHSessionInputRouting: AnyObject {
    func routeInteractiveInput(_ data: Data, from origin: SSHSessionModel)
    func sshSessionDidInvalidateCommandGeneration(_ sshSession: SSHSessionModel)
    func sshSession(
        _ sshSession: SSHSessionModel,
        didChangeWorkingDirectory workingDirectory: String?
    )
    func sshSessionDidChangeRemoteSystemInfo(_ sshSession: SSHSessionModel)
    func closeSSHSessionPane(afterExit sshSession: SSHSessionModel)
}

/// One terminal sshSession inside a pane.
///
/// The screen buffer lives inside libghostty. This model bridges its in-memory
/// terminal backend to one SSH session and exposes connection state to SwiftUI.
@Observable
final class SSHSessionModel: RemotePathDisplaying, Identifiable {
    let commandHistory = CommandHistoryModel()
    var id: UUID { commandHistory.sessionID }
    /// Never optional. Termind ships no local terminal — the App Sandbox has no
    /// route to a login shell worth having, and shipping a crippled one would be
    /// worse than shipping none — so a sshSession is always a sshSession *on* a host.
    var hostID: Host.ID
    var title: String
    var transport: HostTerminalProtocol = .ssh
    private(set) var transportState: ResumableTerminalState?
    var status: ConnectionStatus = .disconnected {
        didSet {
            if !status.isLive, status != .connecting { commandMonitor.endConnection() }
            statusStore?.setConnectionStatus(status, connectionID: id, hostID: hostID)
        }
    }
    var workingDirectory: String? {
        didSet {
            guard workingDirectory != oldValue else { return }
            invalidateCommandGeneration()
            inputRouter?.sshSession(
                self, didChangeWorkingDirectory: workingDirectory
            )
        }
    }
    private(set) var homeResolution: RemoteHomeResolutionState = .pending
    var displayedWorkingDirectory: String? {
        guard let workingDirectory, !homeResolution.isPending else { return nil }
        return displayPath(workingDirectory)
    }

    let commandMonitor = TerminalCommandMonitor()
    private var commandObservation: TerminalCommandObservation?
    var hasUnreadOutput: Bool = false
    /// Find stays with this terminal's scrollback rather than with the transient
    /// SwiftUI pane mounting it, so moving a terminal between panes carries its
    /// open search and retained query along with the buffer they search. Closing
    /// the bar ends Ghostty's highlights but deliberately keeps the query,
    /// matching VS Code when ⌘F is used again in the same terminal.
    ///
    /// Two properties rather than one struct, because Observation invalidates
    /// per stored property. A single `find` value meant every letter typed into
    /// the titlebar Find field invalidated everything that only wanted to know
    /// whether the search was *open* — which is `WorkspaceContentView`, and
    /// which rebuilt every pane in the Workspace and remounted every Ghostty
    /// surface, once per keystroke.
    @ObservationIgnored lazy var find = TerminalFindController(
        perform: { [weak self] in self?.performFindBinding($0) },
        focus: { [weak self] in self?.requestTerminalFocus() }
    )

    /// Resolved once at the beginning of each connection attempt.
    private(set) var isShellIntegrationEnabled = true
    /// Whether the remote shell accepted Termind's authenticated OSC integration.
    var shellIntegrationAvailable: Bool = false
    private(set) var integratedShell: String?
    private(set) var remoteSystemInfo: RemoteSystemInfo? {
        didSet {
            guard remoteSystemInfo != oldValue else { return }
            inputRouter?.sshSessionDidChangeRemoteSystemInfo(self)
        }
    }
    private(set) var isShellPromptReady = false
    private struct ActiveShellCommand {
        var historyID: CommandHistoryEntry.ID?
    }
    private var activeShellCommand: ActiveShellCommand?
    let terminalContext = TerminalContextCoordinator()
    private var hasRuntimeContext = false
    private var historyCharset: RemoteCharset = .utf8
    private var contextHistory: [TerminalContextIdentity: UUID] = [:]
    private(set) var commandGeneratorRevision: UInt64 = 0
    private let commandDraft = TerminalCommandDraftController()

    /// Non-nil while a connection is waiting for the user to approve a first or
    /// additional server fingerprint. No credential is sent before this clears.
    var pendingHostKey: SSHHostKeyPrompt? { connection.pendingHostKey }

    /// Set when this connection needs a login or credentials. The terminal view
    /// presents the editor; the sshSession remains disconnected until it receives
    /// either Continue or Continue and Save.
    var pendingAuthentication: SSHAuthenticationPrompt? {
        get { connection.pendingAuthentication }
        set { connection.pendingAuthentication = newValue }
    }
    let connection = RemoteSessionConnectionController()
    var connectionJourney: ConnectionJourney { connection.journey }

    private let terminalSurface: PersistentTerminalViewOwner
    var terminalState: TerminalViewState { terminalSurface.state }
    /// Owns the native terminal across SplitNode reparenting. Keeping this
    /// beside the sshSession makes the surface lifetime match the SSH sshSession,
    /// rather than the transient SwiftUI branch that currently displays it.
    var terminalViewOwner: PersistentTerminalViewOwner { terminalSurface }
    private weak var statusStore: (any RemoteSessionHostStore)?
    private var ssh: SSHPTYChannel?
    var connectionCoordinator: RemoteConnectionCoordinator?
    private var connectionTask: Task<Void, Never>?
    private var startsOnMount = true
    private(set) var connectionAttemptID: UUID? {
        get { connection.connectionAttemptID }
        set {
            let oldValue = connection.connectionAttemptID
            connection.connectionAttemptID = newValue
            if newValue != oldValue {
                terminalUpload.cancelPendingUpload()
                commandHistory.cancelLoading()
            }
        }
    }
    @ObservationIgnored lazy var terminalUpload = TerminalUploadModel(session: self)
    private var reconnectController: SessionReconnectController { connection.reconnect }
    private var workingDirectoryObservation: AnyCancellable?
    private var terminalActivityObservation: AnyCancellable?
    private(set) var isTerminalActive = false
    /// The live terminal's frozen route and credential IDs. Password, Key, and
    /// passphrase material are resolved only for each attempted transfer
    /// connection and never retained here. Cleared with the SSH connection.
    private(set) var transferSnapshot: SSHAdditionalConnectionSnapshot?
    private var latestViewport = InMemoryTerminalViewport(columns: 80, rows: 24)
    var connectionRoute: SSHConnectionRoute? {
        get { connection.connectionRoute }
        set { connection.connectionRoute = newValue }
    }
    var connectionOrigin: RemoteConnectionOrigin = .library
    var isExternalTemporaryConnection: Bool { !connectionOrigin.allowsPersistence }
    private var transientHost: Host? {
        get { connection.transientHost }
        set { connection.transientHost = newValue }
    }
    private var usernameHint: String?
    private var suppliedAuthentications: [Host.ID: SSHAuthenticationSubmission] {
        get { connection.suppliedAuthentications }
        set { connection.suppliedAuthentications = newValue }
    }
    private var suppliedProxyAuthentications: [Host.ID: SSHProxyAuthenticationSubmission] {
        get { connection.suppliedProxyAuthentications }
        set { connection.suppliedProxyAuthentications = newValue }
    }
    private var temporaryHostKeys: [Host.ID: SSHHostKeyIdentity] {
        get { connection.temporaryHostKeys }
        set { connection.temporaryHostKeys = newValue }
    }
    /// Installed by the Workspace currently holding this sshSession. Weak because
    /// the Workspace owns the pane, which owns this model.
    weak var inputRouter: (any SSHSessionInputRouting)?
    /// Injection point for routing tests. Production sessions leave this nil
    /// and write to their SSH actor as before.
    var inputSink: ((Data) -> Void)?
    /// A caller-supplied command submitted once after the first successful
    /// connection. Authentication and host-key prompts keep it alive; failure,
    /// cancellation, or an explicit disconnect consumes it without running.
    /// Commands generated solely to synchronize an SFTP path opt out of History.
    private struct PendingInitialCommand {
        var command: String
        var recordsInHistory: Bool
    }
    let sessionPersistence = RemoteSessionCoordinator()
    private var pendingInitialCommand: PendingInitialCommand?
    /// Re-resolved from the Host and Snippet library for each physical terminal shell.
    private var pendingConnectionStartupCommand: PendingInitialCommand?
    private var commandExcludedFromHistory: String?
    private var isInitialCommandSubmissionReady = false

    var reconnectState: ReconnectState? { connection.reconnectState }

    func openPTYSFTPChannel(for attemptID: UUID?) async throws -> any SFTPChannelProtocol {
        guard status == .connected, connectionAttemptID == attemptID, let ssh else {
            throw SFTPError.notConnected
        }
        let client = try await ssh.openSFTPChannel()
        guard status == .connected, connectionAttemptID == attemptID, self.ssh === ssh else {
            await client.disconnect()
            throw CancellationError()
        }
        return client
    }

    convenience init(hostID: Host.ID, title: String, initialCommand: String? = nil) {
        self.init(
            hostID: hostID, title: title, initialCommand: initialCommand,
            recordsInitialCommandInHistory: true
        )
    }

    convenience init(
        hostID: Host.ID, title: String, initialCommand: String?,
        recordsInitialCommandInHistory: Bool
    ) {
        self.init(
            hostID: hostID, title: title, transientHost: nil, usernameHint: nil,
            initialCommand: initialCommand,
            recordsInitialCommandInHistory: recordsInitialCommandInHistory
        )
    }

    convenience init(host: Host, usernameHint: String? = nil, initialCommand: String? = nil) {
        self.init(
            host: host, usernameHint: usernameHint, initialCommand: initialCommand,
            recordsInitialCommandInHistory: true
        )
    }

    convenience init(
        host: Host, usernameHint: String? = nil, initialCommand: String?,
        recordsInitialCommandInHistory: Bool
    ) {
        self.init(
            hostID: host.id, title: host.name, transientHost: host,
            usernameHint: usernameHint, initialCommand: initialCommand,
            recordsInitialCommandInHistory: recordsInitialCommandInHistory
        )
    }

    private init(
        hostID: Host.ID, title: String, transientHost: Host?, usernameHint: String?,
        initialCommand: String?, recordsInitialCommandInHistory: Bool
    ) {
        self.hostID = hostID
        self.title = title
        self.usernameHint = usernameHint
        self.pendingInitialCommand = initialCommand.map {
            PendingInitialCommand(
                command: $0, recordsInHistory: recordsInitialCommandInHistory
            )
        }
        let relay = SSHSessionRelay()
        let surface = PersistentTerminalViewOwner(
            write: { data, isInteractiveInput in
                Task { @MainActor in
                    relay.owner?.handleTerminalWrite(
                        data, isInteractiveInput: isInteractiveInput
                    )
                }
            },
            resize: { viewport in
                Task { @MainActor in relay.owner?.resizeSSH(viewport) }
            }
        )
        terminalSurface = surface
        self.transientHost = transientHost
        relay.owner = self
        commandObservation = TerminalCommandObservation(state: terminalSurface.state, monitor: commandMonitor)
        observeWorkingDirectory(from: surface.state, through: relay)
        terminalActivityObservation = surface.state.$isFocused
            .combineLatest(surface.state.$isSurfaceVisible)
            .map { $0 && $1 }
            .removeDuplicates()
            .map { _ in () }
            .merge(
                with: NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification).map { _ in () },
                NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification).map { _ in () }
            )
            .sink { [weak relay] _ in
                Task { @MainActor in relay?.owner?.synchronizeTerminalActivity() }
            }
        sessionPersistence.didChangePrompt = { [weak self] pending in
            if pending { self?.connectionJourney.waitForSessionSelection() } else { self?.connectionJourney.resume() }
        }
    }

    var agentTemporaryTarget: AgentHostTarget? {
        guard statusStore?.host(hostID) == nil, let host = transientHost else { return nil }
        let state: String
        switch status {
        case .disconnected: state = "disconnected"
        case .connecting: state = "connecting"
        case .connected: state = "connected"
        case .reconnecting: state = "reconnecting"
        case .failed: state = "failed"
        }
        return AgentHostTarget(
            id: host.id, displayName: host.name, address: host.displayAddress,
            tags: host.tags, connectionState: state, isTemporary: true,
            groupID: nil, groupPath: nil
        )
    }

    var agentConnectionConfiguration: SSHConnectionConfiguration? {
        guard let transferSnapshot, let statusStore else { return nil }
        return try? statusStore.additionalConnectionRequest(from: transferSnapshot).configuration
    }

    var transferHostStore: (any RemoteSessionHostStore)? { statusStore }

    func additionalConnectionRequest(
        from snapshot: SSHAdditionalConnectionSnapshot
    ) throws -> SSHConnectionRequest {
        guard let statusStore else { throw TermindSSHError.missingCredential }
        return try statusStore.additionalConnectionRequest(from: snapshot)
    }

    func requestTerminalFocus() {
        terminalSurface.requestFocus()
    }

    private func performFindBinding(_ action: String) {
        terminalSurface.performBindingAction(action)
    }

    /// Text arriving at this sshSession's prompt — the one way anything reaches a
    /// sshSession.
    ///
    /// Every programmatic surface that types into a shell comes through here: a
    /// snippet or an AI command card. One choke point
    /// makes broadcast possible — see `Workspace.deliver`; `submit` appends the
    /// newline that the user's own Return key would otherwise supply.
    func insert(_ text: String, submit: Bool = false) {
        invalidateCommandGeneration()
        writeInputDirectly(Data((text + (submit ? "\r" : "")).utf8))
    }

    var canGenerateFromCurrentDraft: Bool {
        status.isLive && isShellIntegrationEnabled && shellIntegrationAvailable && isShellPromptReady
            && TerminalCommandDraftController.supportedShells.contains(integratedShell ?? "")
            && (!hasRuntimeContext || terminalContext.ticket(requiring: [.readDraft, .replaceDraft]) != nil)
    }

    func requestCurrentDraft() async throws -> String {
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
            self?.writeInputDirectly(data)
        }
    }

    /// Clears the shell's edit buffer through the installed line-editor widget,
    /// then inserts one literal command as a bracketed paste. There is
    /// intentionally no carriage return in this payload.
    func insertUploadedPaths(_ paths: [String]) {
        let text = paths.map(RemoteShellCommand.escapeArgument).joined(separator: " ") + " "
        if hasRuntimeContext {
            replaceCurrentDraft(with: text)
            return
        }
        // Write only to this session: broadcast input must not copy local upload paths.
        terminalViewOwner.pasteUploadedText(text)
    }

    var directoryContextTicket: TerminalContextCoordinator.Ticket? {
        terminalContext.ticket(requiring: .directory)
    }

    func isDirectoryContextCurrent(_ ticket: TerminalContextCoordinator.Ticket?) -> Bool {
        guard hasRuntimeContext else { return ticket == nil }
        guard let ticket else { return false }
        return terminalContext.isCurrent(ticket, requiring: .directory)
    }

    func confirmDirectoryContext(_ ticket: TerminalContextCoordinator.Ticket?) async throws {
        guard hasRuntimeContext else { return }
        guard isDirectoryContextCurrent(ticket), let context = terminalContext.active, let ssh else {
            throw TerminalDraftError.unavailable
        }
        do {
            try await ssh.confirmContext(context)
            guard isDirectoryContextCurrent(ticket) else { throw TerminalDraftError.unavailable }
        } catch {
            if isDirectoryContextCurrent(ticket) { receiveRuntimeContext(.init(status: .unknown)) }
            throw error
        }
    }

    func replaceCurrentDraft(with command: String) {
        if hasRuntimeContext {
            guard let ticket = terminalContext.ticket(requiring: .replaceDraft),
                let context = terminalContext.active, let ssh
            else { return }
            Task { [weak self] in
                guard let self, terminalContext.isCurrent(ticket, requiring: .replaceDraft) else { return }
                do {
                    _ = try await ssh.contextDraft(context, replacing: command)
                } catch {
                    if terminalContext.isCurrent(ticket, requiring: .replaceDraft) {
                        receiveRuntimeContext(.init(status: .unknown))
                    }
                }
            }
            return
        }
        writeInputDirectly(commandDraft.replacementPayload(for: command))
    }

    private func invalidateCommandGeneration() {
        commandGeneratorRevision &+= 1
        inputRouter?.sshSessionDidInvalidateCommandGeneration(self)
    }

    private func resetCommandGeneratorShellState() {
        terminalContext.reset()
        if hasRuntimeContext { commandHistory.selectContext(nil, generation: terminalContext.generation) }
        hasRuntimeContext = false
        contextHistory.removeAll()
        integratedShell = nil
        remoteSystemInfo = nil
        isShellPromptReady = false
        shellIntegrationAvailable = false
        isInitialCommandSubmissionReady = false
        pendingConnectionStartupCommand = nil
        activeShellCommand = nil
        commandDraft.cancel()
        invalidateCommandGeneration()
    }

    func connectIfNeeded(using store: any RemoteSessionHostStore) {
        guard startsOnMount, status == .connecting else { return }
        connect(using: store)
    }

    func connect(using store: any RemoteSessionHostStore) {
        if transport.isResumable, let ssh {
            Task { try? await ssh.retryTransport() }
            return
        }
        startsOnMount = false
        startConnection(using: store)
    }

    private func startConnection(using store: any RemoteSessionHostStore) {
        commandMonitor.endConnection()
        resetCommandGeneratorShellState()
        homeResolution = .unavailable
        let reconnecting = connection.hasConnectedOnce && connection.isRecovering
        workingDirectory = nil
        transferSnapshot = nil
        commandExcludedFromHistory = nil
        statusStore = store
        let attemptID = UUID()
        connectionAttemptID = attemptID
        transportState = nil
        if let ssh { Task { await ssh.disconnect() } }
        ssh = nil
        guard let host = connectionHost(hostID, using: store) else {
            connection.stopRecovery()
            connectionAttemptID = nil
            status = .failed(String(localized: AppStrings.Connections.theHostIsNoLongerAvailable))
            connectionJourney.fail(String(localized: AppStrings.Connections.theHostIsNoLongerAvailable))
            return
        }
        guard host.isEnabled(transport) else {
            startsOnMount = false
            status = .failed(TerminalTransportError.unsupportedRoute.localizedDescription)
            connectionJourney.fail(TerminalTransportError.unsupportedRoute.localizedDescription)
            return
        }
        isShellIntegrationEnabled =
            transport != .mosh
            && host.shellIntegrationMode.isEnabled(
                globalSetting: DesktopSettingsKey.isShellIntegrationEnabled)
        if pendingInitialCommand == nil,
            let snippetID = host.startupSnippetID,
            let body = store.snippet(snippetID)?.body,
            !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            pendingConnectionStartupCommand = PendingInitialCommand(
                command: body, recordsInHistory: true
            )
        }
        homeResolution = isShellIntegrationEnabled ? .pending : .unavailable
        let route = connectionRoute?.hosts ?? store.route(for: host)
        let identity = store.identity(for: host)
        let stagedAuthentication = suppliedAuthentications[host.id]
        let username =
            stagedAuthentication?.username
            ?? (host.isTailscaleManaged ? store.savedTailscaleUsername(for: host) : identity?.username)
            ?? usernameHint
        connectionJourney.begin(
            host: host, route: route, purpose: .terminal(transport), username: username,
            mode: reconnecting ? .reconnection : .connection
        )
        if let proxyHost = suppliedProxyAuthentications.firstHostRequiringProxyPassword(in: route) {
            requestProxyAuthentication(for: proxyHost, using: store)
            return
        }
        if let passwordHost = suppliedAuthentications.firstHostRequiringPassword(in: route),
            let submission = suppliedAuthentications[passwordHost.id]
        {
            requestAuthentication(
                for: passwordHost, username: submission.username,
                selectedKeyID: submission.keyID, requiresPassphrase: false
            )
            return
        }
        if let passphraseHost = suppliedAuthentications.firstHostRequiringPassphrase(
            in: route, key: store.key, requiresEntry: store.requiresPassphraseEntry
        ), let submission = suppliedAuthentications[passphraseHost.id] {
            requestAuthentication(
                for: passphraseHost, username: submission.username,
                selectedKeyID: submission.keyID, requiresPassphrase: true,
                preserveSubmission: true
            )
            return
        }
        guard let username, !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            requestAuthentication(
                for: host, username: "", selectedKeyID: identity?.keyID,
                requiresPassphrase: false
            )
            return
        }
        let attemptAuthentications = suppliedAuthentications.takeAuthenticationSecrets()
        let attemptProxyAuthentications = suppliedProxyAuthentications.takeProxyAuthenticationSecrets()
        let suppliedAuthentication = attemptAuthentications[host.id]
        var credentials: [SSHCredentials] = []
        var credentialFailures: [String] = []
        var hasConfiguredCredential = false
        let selectedKeyID: SSHKeyRef.ID?
        if let suppliedAuthentication {
            selectedKeyID = suppliedAuthentication.keyID
        } else {
            selectedKeyID = identity?.keyID
        }
        if let suppliedAuthentication {
            hasConfiguredCredential =
                suppliedAuthentication.keyID != nil
                || suppliedAuthentication.hasPassword
                || suppliedAuthentication.identityID.flatMap(store.identity)?.hasSecret == true
            if let keyID = suppliedAuthentication.keyID {
                if let key = store.key(keyID) {
                    do {
                        if let credential = try store.connectionKeySecretCredential(for: key) {
                            credentials.append(
                                credential.sshCredential(
                                    for: key, passphraseOverride: suppliedAuthentication.passphraseForConnection()
                                )
                            )
                        } else {
                            credentialFailures.append(
                                String(localized: AppStrings.Terminal.theSelectedKeyHasNoSavedPrivateKey)
                            )
                        }
                    } catch {
                        credentialFailures.append(error.localizedDescription)
                    }
                } else {
                    credentialFailures.append(
                        String(localized: AppStrings.Terminal.theSelectedKeyIsNoLongerAvailable)
                    )
                }
            }
            if let password = suppliedAuthentication.passwordForConnection() {
                credentials.append(.password(password))
            } else if let identityID = suppliedAuthentication.identityID,
                let selectedIdentity = store.identity(identityID), selectedIdentity.usesPassword
            {
                do {
                    if let password = try store.connectionPasswordSecret(for: selectedIdentity) {
                        credentials.append(.password(password))
                    } else {
                        credentialFailures.append(
                            String(localized: AppStrings.Terminal.theSavedPasswordIsNoLongerAvailable)
                        )
                    }
                } catch {
                    credentialFailures.append(error.localizedDescription)
                }
            }
        } else if let identity {
            let resolution = store.sshCredentials(for: identity)
            if let keyID = resolution.requiredPassphraseKeyID {
                requestAuthentication(
                    for: host, username: username, selectedKeyID: keyID,
                    requiresPassphrase: true
                )
                return
            }
            credentials = resolution.credentials
            credentialFailures = resolution.failures
            hasConfiguredCredential = resolution.hasConfiguredCredential
        }
        if credentials.isEmpty, suppliedAuthentication == nil, hasConfiguredCredential {
            requestAuthentication(
                for: host, username: username,
                selectedKeyID: selectedKeyID,
                failureMessage: hasConfiguredCredential
                    ? credentialFailures.joined(separator: "\n")
                    : nil
            )
            return
        }

        let proxy: SSHTransportProxy?
        let jumps: [SSHRouteHopConfiguration]
        let expectedHostKeys: Set<SSHHostKeyIdentity>
        do {
            proxy = try store.transportProxy(
                for: host, submission: attemptProxyAuthentications[host.id])
            if let connectionRoute {
                jumps = try store.sshJumpConfigurations(
                    for: connectionRoute, submissions: attemptAuthentications,
                    proxySubmissions: attemptProxyAuthentications,
                    temporaryHostKeys: temporaryHostKeys, trustPolicy: .allowChallenge
                )
            } else {
                jumps = try store.sshJumpConfigurations(
                    for: host, submissions: attemptAuthentications,
                    proxySubmissions: attemptProxyAuthentications,
                    temporaryHostKeys: temporaryHostKeys, trustPolicy: .allowChallenge
                )
            }
            expectedHostKeys = try store.expectedHostKeys(
                for: host, temporaryHostKeys: temporaryHostKeys,
                trustPolicy: .allowChallenge
            )
        } catch {
            if let sshError = error as? TermindSSHError,
                sshError.shouldRequestAuthentication,
                let id = sshError.routeHostID,
                let jump = connectionHost(id, using: store)
            {
                if sshError.isProxyAuthentication {
                    connectionAttemptID = nil
                    requestProxyAuthentication(
                        for: jump, using: store,
                        failureMessage: sshError.localizedDescription,
                        mode: sshError.isServerAuthenticationChallenge ? .serverChallenge : .localIdentity)
                    return
                }
                let identity = store.identity(for: jump)
                let submitted = suppliedAuthentications[jump.id]
                let retryNeedsPassphrase =
                    submitted?.hasPassphrase != true
                    && (submitted?.keyID ?? identity?.keyID)
                        .flatMap { store.key($0) }?.requiresPassphraseEntry == true
                connectionAttemptID = nil
                requestAuthentication(
                    for: jump,
                    username: submitted?.username ?? identity?.username ?? connectionRoute?.usernames[jump.id] ?? "",
                    selectedKeyID: submitted?.keyID ?? identity?.keyID,
                    failureMessage: sshError.localizedDescription,
                    requiresPassphrase: retryNeedsPassphrase,
                    preserveSubmission: retryNeedsPassphrase && submitted != nil
                )
                return
            }
            connectionAttemptID = nil
            handleConnectionAttemptFailure(
                error, store: store, reconnecting: reconnecting
            )
            return
        }

        connection.clearHostKeyPrompt()
        connectionTask?.cancel()
        status = reconnecting ? .reconnecting : .connecting
        let authenticationReference: SSHAuthenticationReference
        if let identityID = suppliedAuthentication?.identityID ?? (suppliedAuthentication == nil ? identity?.id : nil) {
            authenticationReference = SSHAuthenticationReference(
                identityID: identityID,
                username: username,
                permitsNone: identity?.hasSecret == false,
                hasEphemeralSecret: suppliedAuthentication?.hasPassword == true
                    || suppliedAuthentication?.hasPassphrase == true
            )
        } else {
            authenticationReference = SSHAuthenticationReference(
                fallbackKeyID: selectedKeyID,
                username: username,
                permitsNone: selectedKeyID == nil && suppliedAuthentication?.hasPassword != true,
                hasEphemeralSecret: suppliedAuthentication?.hasPassword == true
                    || suppliedAuthentication?.hasPassphrase == true
            )
        }
        connectionTask = Task { [weak self, weak store] in
            guard let self, let store else { return }
            do {
                try await openSSH(
                    host: host, username: username, credentials: credentials,
                    expectedHostKeys: expectedHostKeys, proxy: proxy, jumps: jumps,
                    authenticationReference: authenticationReference, attemptID: attemptID,
                    authorizeHostKey: { [weak self] challenge in
                        guard let self else { throw CancellationError() }
                        return await self.connection.authorizeHostKey(challenge)
                    }
                )
            } catch is CancellationError {
                guard connectionAttemptID == attemptID else { return }
                connectionAttemptID = nil
                status = .disconnected
                connection.stopRecovery()
                connectionJourney.fail(String(localized: AppStrings.Connections.connectionCancelled))
            } catch {
                guard connectionAttemptID == attemptID else { return }
                connectionAttemptID = nil
                if let sshError = error as? TermindSSHError,
                    sshError.shouldRequestAuthentication
                {
                    let authenticationHost: Host
                    if let id = sshError.routeHostID, let jump = connectionHost(id, using: store) {
                        authenticationHost = jump
                    } else {
                        authenticationHost = host
                    }
                    let authenticationIdentity = store.identity(for: authenticationHost)
                    if sshError.isProxyAuthentication {
                        requestProxyAuthentication(
                            for: authenticationHost, using: store,
                            failureMessage: sshError.localizedDescription,
                            mode: sshError.isServerAuthenticationChallenge ? .serverChallenge : .localIdentity)
                        return
                    }
                    let submitted = suppliedAuthentications[authenticationHost.id]
                    let authenticationKeyID =
                        submitted?.keyID
                        ?? authenticationIdentity?.keyID ?? (authenticationHost.id == host.id ? selectedKeyID : nil)
                    let retryNeedsPassphrase =
                        submitted?.requiresPasswordReentry != true
                        && submitted?.hasPassphrase != true
                        && authenticationKeyID.flatMap { store.key($0) }?.hasPassphrase == true
                    let returnsToIdentity = submitted?.requiresPassphraseReentry == true
                    requestAuthentication(
                        for: authenticationHost,
                        username: submitted?.username ?? authenticationIdentity?.username
                            ?? connectionRoute?.usernames[authenticationHost.id]
                            ?? (authenticationHost.id == host.id ? username : ""),
                        selectedKeyID: authenticationKeyID,
                        failureMessage: (credentialFailures
                            + [sshError.localizedDescription]).joined(separator: "\n"),
                        requiresPassphrase: retryNeedsPassphrase,
                        mode: !returnsToIdentity && sshError.isServerAuthenticationChallenge
                            ? .serverChallenge : .localIdentity,
                        preserveSubmission: retryNeedsPassphrase && submitted != nil
                    )
                } else {
                    handleConnectionAttemptFailure(
                        error, store: store, reconnecting: reconnecting
                    )
                }
            }
        }
    }

    func continueAuthentication(
        identityID: Identity.ID?, username: String, password: String?, passphrase: String?,
        keyID: SSHKeyRef.ID?, save: Bool, using store: any RemoteSessionHostStore
    ) {
        connection.continueAuthentication(
            identityID: identityID, username: username, password: password, passphrase: passphrase,
            keyID: keyID, save: save, destinationID: hostID, using: store
        ) { host, submission in
            if host.id == hostID { usernameHint = submission.username }
            connectionRoute?.usernames[host.id] = submission.username
        } saveIdentity: { host, submission, selectedIdentity in
            if let route = connectionRoute {
                let saved = try store.saveConnectionRoute(
                    route, authentication: submission, authenticationHostID: host.id, suppliedPassword: password)
                adoptSavedRoute(saved, replacing: route, using: store)
            } else {
                let saved = try store.saveAuthentication(
                    submission, for: host, selectedIdentity: selectedIdentity, suppliedPassword: password)
                if saved.id == hostID { transientHost = saved }
            }
        } onFailure: { failure in
            switch failure {
            case .proxy(let host, let error):
                requestProxyAuthentication(for: host, using: store, failureMessage: error.localizedDescription)
            case .identity(let host, let username, let keyID, _, let error):
                requestAuthentication(
                    for: host, username: username, selectedKeyID: keyID,
                    failureMessage: error.localizedDescription,
                    requiresPassphrase:
                        keyID.flatMap { store.key($0) }.map { store.requiresPassphraseEntry(for: $0) } == true)
            }
        } connect: {
            connect(using: store)
        }
    }

    func trustAndConnect(_ observation: SSHHostKeyObservation, using store: any RemoteSessionHostStore) {
        connection.trustHostKey(observation, using: store)
    }

    func continueWithTemporaryHostKey(_ observation: SSHHostKeyObservation) {
        _ = connection.useTemporaryHostKey(observation)
    }

    func disconnect() {
        sessionPersistence.cancel()
        commandHistory.cancelLoading()
        terminalUpload.cancelPendingUpload()
        commandMonitor.endConnection()
        startsOnMount = false
        resetCommandGeneratorShellState()
        workingDirectory = nil
        homeResolution = .unavailable
        transferSnapshot = nil
        pendingInitialCommand = nil
        pendingConnectionStartupCommand = nil
        commandExcludedFromHistory = nil
        connectionAttemptID = nil
        connection.disconnect()
        connectionTask?.cancel()
        connectionTask = nil
        if let ssh { Task { await ssh.disconnect() } }
        ssh = nil
        status = .disconnected
    }

    func retryReconnectNow() {
        if transport.isResumable, let ssh {
            Task { try? await ssh.retryTransport() }
            return
        }
        reconnectController.retryNow()
    }

    func stopReconnecting() {
        guard let reconnectState else { return }
        connection.stopRecovery()
        connectionAttemptID = nil
        connectionTask?.cancel()
        connectionTask = nil
        if let ssh { Task { await ssh.disconnect() } }
        ssh = nil
        status = .failed(reconnectState.lastError)
        connectionJourney.fail(reconnectState.lastError)
    }

    private func openSSH(
        host: Host, username: String, credentials: [SSHCredentials],
        expectedHostKeys: Set<SSHHostKeyIdentity>,
        proxy: SSHTransportProxy?, jumps: [SSHRouteHopConfiguration],
        authenticationReference: SSHAuthenticationReference, attemptID: UUID,
        authorizeHostKey: @escaping SSHHostKeyAuthorizer
    ) async throws {
        let wasReconnecting = connection.isRecovering
        let presentsConnectionJourney = connectionJourney.isPresented
        var configuration = SSHConnectionConfiguration(
            hostID: host.id, host: host.host, port: host.port, username: username,
            credentials: credentials, expectedHostKeys: expectedHostKeys,
            proxy: proxy, jumps: jumps,
            charset: host.charset,
            authenticationReference: authenticationReference
        )
        guard let store = statusStore else { throw TailscaleConfigurationError.unavailable }
        configuration.beforeConnect = store.connectionWakeAction(for: jumps.map(\.id) + [host.id])
        configuration.network = try store.tailscaleNetwork(
            for: (connectionRoute?.hosts ?? store.route(for: host)).first ?? host)
        configuration.tailscaleNodeID = host.tailscale?.stableNodeID
        let terminalSurface = terminalSurface
        commandMonitor.beginConnection()
        commandMonitor.requireScopedEvents()
        let actor = (connectionCoordinator ?? RemoteConnectionCoordinator()).makePTYChannel(
            output: { data in terminalSurface.receive(data) },
            exit: { [weak self] result in
                Task { @MainActor in
                    guard let self, self.connectionAttemptID == attemptID else { return }
                    self.handleRemoteExit(result)
                }
            },
            shellIntegration: { [weak self] event in
                Task { @MainActor in
                    guard let self, self.connectionAttemptID == attemptID else { return }
                    self.receiveShellIntegrationEvent(event)
                }
            }
        )
        ssh = actor
        historyCharset = host.charset
        do {
            if transport.isResumable {
                let snapshot = store.additionalConnectionSnapshot(from: configuration)
                let port = host.terminalTransports.eternalTerminalPort
                let requestFactory: @Sendable (Bool) async throws -> SSHConnectionRequest = {
                    [weak self, weak store] authenticatingTarget in
                    guard let self, let store, await self.connectionAttemptID == attemptID else {
                        throw CancellationError()
                    }
                    return try await store.resumableRouteRequest(
                        from: snapshot, authorizeHostKey: authorizeHostKey,
                        keyboardInteractive: { [weak self] challenge in
                            guard let self, await self.connectionAttemptID == attemptID else {
                                throw CancellationError()
                            }
                            return try await self.connection.answerKeyboardInteractive(challenge)
                        },
                        securityKeySigning: { [weak self] request in
                            guard let self, await self.connectionAttemptID == attemptID else {
                                throw CancellationError()
                            }
                            return try await self.connection.signWithSecurityKey(request)
                        },
                        hostKeyConstraints: self.connectionOrigin.hostKeyConstraints,
                        authenticatingTarget: authenticatingTarget)
                }
                await actor.configureTransport(
                    transport, options: host.terminalTransports,
                    route: {
                        try await TerminalTransportRoute.open(using: requestFactory(false), port: port)
                    },
                    control: { command in
                        try await TerminalTransportRoute.execute(command, using: requestFactory(true))
                    },
                    stateChanged: { [weak self] state in
                        Task { @MainActor in
                            guard let self, self.connectionAttemptID == attemptID else { return }
                            self.receiveTransportState(state)
                        }
                    })
            }
            await actor.configureEnvironment(host.environmentVariables) { variables in
                let list = variables.joined(separator: ", ")
                let warning = String(localized: AppStrings.Terminal.rejectedEnvironmentVariables(list))
                terminalSurface.receive(Data("\r\n⚠︎ \(warning)\r\n".utf8))
            }
            let persistence = sessionPersistence
            let explicit = pendingInitialCommand?.command
            let startup = explicit ?? pendingConnectionStartupCommand?.command
            let integration = isShellIntegrationEnabled
            if host.sessionPersistence.enabled || persistence.attachment != nil || persistence.requiresSelection {
                persistence.didChangeAttachment = { [weak self] reference in
                    guard let self, self.connectionAttemptID == attemptID, reference != nil else { return }
                    self.pendingInitialCommand = nil
                    self.pendingConnectionStartupCommand = nil
                }
                await actor.configureStartup { execute in
                    try await persistence.prepare(
                        preferences: host.sessionPersistence, registry: .live, execute: execute,
                        hostID: host.id, endpoint: "\(host.host):\(host.sshPort)", username: username,
                        startupCommand: startup, requiresNewSession: explicit != nil, shellIntegration: integration,
                        environment: host.environmentVariables)
                }
            }
            await actor.setTerminalActive(isTerminalActive)
            try await actor.connect(
                using: SSHConnectionRequest(
                    configuration: configuration,
                    authorizeHostKey: authorizeHostKey,
                    keyboardInteractive: { [weak self] challenge in
                        guard let self, await self.connectionAttemptID == attemptID else { throw CancellationError() }
                        return try await self.connection.answerKeyboardInteractive(challenge)
                    },
                    securityKeySigning: { [weak self] request in
                        guard let self, await self.connectionAttemptID == attemptID else { throw CancellationError() }
                        return try await self.connection.signWithSecurityKey(request)
                    },
                    hostKeyConstraints: connectionOrigin.hostKeyConstraints
                ),
                shellIntegrationEnabled: isShellIntegrationEnabled,
                columns: latestViewport.columns, rows: latestViewport.rows,
                progress: connection.progressHandler(attemptID: attemptID)
            )
            try Task.checkCancellation()
            guard connectionAttemptID == attemptID else { throw CancellationError() }
            guard transportState != .ended else { return }
            transferSnapshot =
                statusStore?.additionalConnectionSnapshot(from: configuration)
                ?? SSHAdditionalConnectionSnapshot(configuration: configuration)
            suppliedAuthentications.removeAll()
            suppliedProxyAuthentications.removeAll()
            temporaryHostKeys.removeAll()
            _ = connection.markConnected()
            status = .connected
            if transport == .ssh {
                if hasRuntimeContext, terminalContext.active?.historySource != nil {
                    loadContextHistory()
                } else {
                    commandHistory.load(
                        using: RemoteShellHistoryLoader(channel: actor, charset: host.charset), source: nil)
                }
            }
            if sessionPersistence.attachment != nil {
                pendingInitialCommand = nil
                pendingConnectionStartupCommand = nil
                homeResolution = .unavailable
            }
            if presentsConnectionJourney {
                connectionJourney.succeed()
            } else {
                connectionJourney.hide()
            }
            if wasReconnecting, transport == .ssh, sessionPersistence.attachment == nil {
                appendTerminalNotice(
                    String(localized: AppStrings.Terminal.reconnectedANewRemoteShellHasStarted)
                )
            }
            if !isShellIntegrationEnabled {
                isInitialCommandSubmissionReady = true
            }
            submitPendingInitialCommandIfReady()
        } catch {
            await actor.disconnect()
            if ssh === actor { ssh = nil }
            throw error
        }
    }

    func receiveTransportState(_ state: ResumableTerminalState) {
        guard transportState != .ended else { return }
        transportState = state
        switch state {
        case .connected:
            status = .connected
            connectionJourney.hide()
        case .recovering:
            status = .reconnecting
        case .ended:
            // These protocols report session end, not the remote process's numeric exit status.
            handleRemoteExit(.success(0))
        case .failed:
            connection.resetRecovery()
            status = .failed(TerminalTransportError.sessionFailed.localizedDescription)
        case .suspended: status = .reconnecting
        case .connecting, .closed: break
        }
    }

    /// A normal remote-shell exit owns the pane lifecycle, not the reusable
    /// Ghostty surface lifecycle. Marking the in-memory backend as finished
    /// makes the surface permanently stop producing input, which is incorrect
    /// for Termind's retained pane model. Close the pane through its current
    /// Workspace instead; transport failures remain visible for reconnection.
    func terminatePersistentSession(
        _ reference: RemoteSessionReference, isCurrentOwner: @MainActor () -> Bool = { true }
    ) async throws {
        guard sessionPersistence.attachment == reference, let channel = ssh else {
            throw RemoteSessionFailure.sessionMissing
        }
        try await channel.releaseTerminalForControl()
        status = .disconnected
        resetCommandGeneratorShellState()
        workingDirectory = nil
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
    }

    func handleRemoteExit(_ result: Result<Int32, TermindSSHError>) {
        resetCommandGeneratorShellState()
        workingDirectory = nil
        terminalUpload.cancelPendingUpload()
        if case .success(let exitCode) = result, let reference = sessionPersistence.attachment, let channel = ssh {
            let attemptID = connectionAttemptID
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
                guard self.connectionAttemptID == attemptID, self.sessionPersistence.attachment == reference else {
                    return
                }
                let shouldClose = self.sessionPersistence.finishExit(exitCode: exitCode, sessionExists: sessionExists)
                await channel.disconnect()
                guard self.connectionAttemptID == attemptID else { return }
                self.ssh = nil
                self.connection.resetRecovery()
                self.status = .disconnected
                if shouldClose {
                    self.inputRouter?.closeSSHSessionPane(afterExit: self)
                    return
                }
                self.appendTerminalNotice(
                    String(
                        localized: exitCode != 0
                            ? AppStrings.SessionPersistence.failed
                            : self.sessionPersistence.detached
                                ? AppStrings.SessionPersistence.detached : AppStrings.SessionPersistence.ended))
            }
            return
        }

        resetCommandGeneratorShellState()
        workingDirectory = nil
        homeResolution = .unavailable
        transferSnapshot = nil
        connectionAttemptID = nil
        ssh = nil
        switch result {
        case .success:
            connection.resetRecovery()
            status = .disconnected
            inputRouter?.closeSSHSessionPane(afterExit: self)
        case .failure(let error):
            beginAutomaticReconnect(after: error.localizedDescription)
        }
    }

    private func handleConnectionAttemptFailure(
        _ error: any Error, store: any RemoteSessionHostStore, reconnecting: Bool
    ) {
        connectionAttemptID = nil
        if transport.isResumable {
            connection.resetRecovery()
            status = .failed(error.localizedDescription)
            connectionJourney.fail(error.localizedDescription)
            return
        }
        if connection.hasConnectedOnce || reconnecting {
            scheduleReconnect(after: error.localizedDescription, using: store)
        } else {
            status = .failed(error.localizedDescription)
            connectionJourney.fail(
                error.localizedDescription, at: (error as? TermindSSHError)?.routeHostID
            )
        }
    }

    private func beginAutomaticReconnect(after message: String) {
        guard connection.hasConnectedOnce, let store = statusStore else {
            status = .failed(message)
            return
        }
        appendTerminalNotice(String(localized: AppStrings.Connections.connectionLostReconnectingProgress))
        scheduleReconnect(after: message, using: store)
    }

    private func scheduleReconnect(after message: String, using store: any RemoteSessionHostStore) {
        connection.scheduleReconnect(
            after: message, hostID: hostID, using: store,
            purpose: .terminal(transport), route: connectionRoute, usernameHint: usernameHint
        ) {
            resetCommandGeneratorShellState()
            connectionAttemptID = nil
            connectionTask?.cancel()
            connectionTask = nil
            if let ssh { Task { await ssh.disconnect() } }
            ssh = nil
            transferSnapshot = nil
            status = .reconnecting
        } retry: { [weak self] store in
            self?.startConnection(using: store)
        }
    }

    private func appendTerminalNotice(_ message: String) {
        terminalSurface.appendNotice(message)
    }

    private func requestAuthentication(
        for host: Host, username: String,
        selectedKeyID: SSHKeyRef.ID?, failureMessage: String? = nil,
        requiresPassphrase: Bool = false,
        mode: SSHAuthenticationPrompt.Mode = .localIdentity,
        preserveSubmission: Bool = false
    ) {
        guard let store = statusStore else { return }
        connection.pauseForUserInteraction()
        if !preserveSubmission { suppliedAuthentications[host.id] = nil }
        pendingAuthentication = SSHAuthenticationPromptResolver.host(
            host, using: store,
            submission: preserveSubmission ? suppliedAuthentications[host.id] : nil,
            username: username, selectedKeyID: selectedKeyID,
            failureMessage: failureMessage?.isEmpty == false ? failureMessage : nil,
            mode: mode, requiresPassphrase: requiresPassphrase,
            allowsSaving: connectionOrigin.allowsPersistence
        )
        status = .disconnected
        if host.isTailscaleManaged {
            connectionJourney.waitForTailscaleUsername(at: host.id, failure: failureMessage)
            return
        }
        switch mode {
        case .localIdentity:
            if requiresPassphrase {
                connectionJourney.waitForLocalPassphrase(
                    at: host.id, failure: failureMessage
                )
            } else {
                connectionJourney.waitForLocalIdentity(
                    at: host.id, failure: failureMessage
                )
            }
        case .serverChallenge:
            connectionJourney.waitForAuthentication(at: host.id, failure: failureMessage)
        }
    }

    private func requestProxyAuthentication(
        for host: Host, using store: any RemoteSessionHostStore,
        failureMessage: String? = nil,
        mode: SSHAuthenticationPrompt.Mode = .localIdentity
    ) {
        guard host.proxy != nil else { return }
        connection.pauseForUserInteraction()
        let staged = suppliedProxyAuthentications[host.id]
        suppliedProxyAuthentications[host.id] = nil
        pendingAuthentication = SSHAuthenticationPromptResolver.proxy(
            for: host, using: store, submission: staged,
            failureMessage: failureMessage, mode: mode,
            allowsSaving: connectionOrigin.allowsPersistence)
        status = .disconnected
        connectionJourney.waitForProxyAuthentication(at: host.id, failure: failureMessage)
    }

    func connectionHost(_ id: Host.ID, using store: any RemoteSessionHostStore) -> Host? {
        connection.connectionHost(id, destinationID: hostID, using: store)
    }

    private func adoptSavedRoute(
        _ saved: SSHConnectionRoute, replacing route: SSHConnectionRoute, using store: any RemoteSessionHostStore
    ) {
        let mapping = Dictionary(uniqueKeysWithValues: zip(route.hosts, saved.hosts).map { ($0.id, $1.id) })
        suppliedAuthentications = Dictionary(
            uniqueKeysWithValues: suppliedAuthentications.map {
                (mapping[$0.key] ?? $0.key, $0.value)
            })
        suppliedProxyAuthentications = Dictionary(
            uniqueKeysWithValues: suppliedProxyAuthentications.map {
                (mapping[$0.key] ?? $0.key, $0.value)
            })
        temporaryHostKeys = Dictionary(
            uniqueKeysWithValues: temporaryHostKeys.map {
                (mapping[$0.key] ?? $0.key, $0.value)
            })
        if let destination = saved.hosts.last {
            if hostID != destination.id {
                store.setConnectionStatus(.disconnected, connectionID: id, hostID: hostID)
            }
            hostID = destination.id
            transientHost = destination
            usernameHint = saved.usernames[destination.id]
        }
        connectionRoute = saved
    }

    func copyForReconnect() -> SSHSessionModel {
        let host = transientHost ?? Host(id: hostID, name: title, host: title)
        let copy = SSHSessionModel(host: host, usernameHint: usernameHint)
        copy.transport = transport
        copy.sessionPersistence.attachment = sessionPersistence.attachment
        copy.connectionRoute = connectionRoute
        copy.connectionOrigin = connectionOrigin
        copy.connectionCoordinator = connectionCoordinator
        return copy
    }

    /// Routes terminal-produced bytes only when they came from an explicitly
    /// captured user interaction. Mouse/focus reports and protocol replies use
    /// the direct path even while Broadcast Input is enabled.
    func handleTerminalWrite(_ data: Data, isInteractiveInput: Bool) {
        if isInteractiveInput { invalidateCommandGeneration() }
        if isInteractiveInput, let inputRouter {
            inputRouter.routeInteractiveInput(data, from: self)
        } else {
            writeInputDirectly(data)
        }
    }

    /// The terminal side of the routing boundary. Broadcast targets call this
    /// rather than feeding bytes back through the router, preventing recursion.
    func writeInputDirectly(_ data: Data) {
        terminalContext.noteInput()
        if let inputSink {
            inputSink(data)
            return
        }
        guard let ssh else { return }
        Task { await ssh.write(data) }
    }

    private func resizeSSH(_ viewport: InMemoryTerminalViewport) {
        latestViewport = viewport
        guard let ssh else { return }
        Task {
            await ssh.resize(
                columns: viewport.columns, rows: viewport.rows,
                widthPixels: viewport.widthPixels, heightPixels: viewport.heightPixels
            )
        }
    }

    private func synchronizeTerminalActivity() {
        // First responder can be retained in a non-key window. Window events must
        // recheck native focus even when Ghostty's last published value is unchanged.
        let active =
            terminalState.isFocused && terminalState.isSurfaceVisible && terminalViewOwner.hasActiveKeyboardFocus
        guard active != isTerminalActive else { return }
        isTerminalActive = active
        guard let ssh else { return }
        Task { [weak self] in
            guard let self, self.ssh === ssh, self.isTerminalActive == active else { return }
            await ssh.setTerminalActive(active)
        }
    }

    /// Ghostty parses OSC 7 and publishes the decoded remote path on its view
    /// state. Bridge that dependency-owned state into the sshSession so every Termind
    /// surface reads one observable source of truth.
    private func observeWorkingDirectory(
        from state: TerminalViewState,
        through relay: SSHSessionRelay
    ) {
        workingDirectoryObservation = state.$workingDirectory.sink { [weak relay] path in
            Task { @MainActor in
                guard let owner = relay?.owner, owner.isShellIntegrationEnabled, !owner.hasRuntimeContext else {
                    return
                }
                owner.workingDirectory = path?.isEmpty == false ? path : nil
            }
        }
    }

    func receiveShellIntegrationEvent(_ event: SSHShellIntegrationEvent) {
        guard isShellIntegrationEnabled else { return }
        if case .runtime(let update) = event {
            receiveRuntimeContext(update)
            return
        }
        guard !hasRuntimeContext else { return }
        commandMonitor.receiveShellEvent(event)
        switch event {
        case .runtime: break
        case .available(let shell, let systemInfo, let homeDirectory):
            if let homeDirectory, homeDirectory.hasPrefix("/") {
                homeResolution = .resolved(RemotePath.normalized(homeDirectory))
            } else {
                homeResolution = .unavailable
            }
            integratedShell = shell
            remoteSystemInfo = systemInfo
            statusStore?.recordRemoteSystemInfo(systemInfo, for: hostID)
            isShellPromptReady = false
            shellIntegrationAvailable = true
            isInitialCommandSubmissionReady = true
            invalidateCommandGeneration()
            inputRouter?.sshSession(self, didChangeWorkingDirectory: workingDirectory)
            submitPendingInitialCommandIfReady()
        case .systemInfo(let systemInfo):
            remoteSystemInfo = systemInfo
            statusStore?.recordRemoteSystemInfo(systemInfo, for: hostID)
        case .homeResolutionUnavailable:
            homeResolution = .unavailable
            inputRouter?.sshSession(self, didChangeWorkingDirectory: workingDirectory)
            isInitialCommandSubmissionReady = true
            submitPendingInitialCommandIfReady()
        case .promptReady:
            isShellPromptReady = true
            isInitialCommandSubmissionReady = true
            invalidateCommandGeneration()
            submitPendingInitialCommandIfReady()
        case .commandStarted(let command):
            isShellPromptReady = false
            invalidateCommandGeneration()
            activeShellCommand = ActiveShellCommand(
                historyID: recordExecutedCommand(command)
            )
        case .commandFinished(let status, let duration):
            recordCommandCompletion(exitStatus: status, reportedDuration: duration)
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
            terminalUpload.cancelPendingUpload()
            invalidateCommandGeneration()
        }
        workingDirectory = terminalContext.directory
        integratedShell = terminalContext.active?.shell
        shellIntegrationAvailable = terminalContext.active?.capabilities.contains(.commandLifecycle) == true
        isShellPromptReady = terminalContext.active?.promptReady == true
        if let home = terminalContext.active?.home {
            homeResolution = .resolved(RemotePath.normalized(home))
        } else {
            homeResolution = .unavailable
        }
        for event in events {
            switch event.payload {
            case .commandStarted(let command):
                contextHistory[event.context] = recordExecutedCommand(command)
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
        guard transport == .ssh, let context, let source, let ssh, commandHistory.loadError == nil else { return }
        commandHistory.load(
            using: RemoteShellHistoryLoader(channel: ssh, charset: historyCharset, context: context), source: source)
    }

    /// Submits an explicit one-shot launch command, or this connection's freshly
    /// resolved Host startup command. Keeping the History exclusion next to the
    /// write ensures it is armed only when the command actually runs.
    func submitPendingInitialCommand() {
        let initialCommand: PendingInitialCommand
        if let explicit = pendingInitialCommand {
            initialCommand = explicit
            pendingInitialCommand = nil
        } else if let startup = pendingConnectionStartupCommand {
            initialCommand = startup
            pendingConnectionStartupCommand = nil
        } else {
            return
        }
        if !initialCommand.recordsInHistory {
            commandExcludedFromHistory = CommandHistoryEntry.normalizingLineContinuations(
                in: initialCommand.command
            )
        }
        insert(initialCommand.command, submit: true)
    }

    private func submitPendingInitialCommandIfReady() {
        guard status.isLive, isInitialCommandSubmissionReady else { return }
        submitPendingInitialCommand()
    }

    @discardableResult
    func recordExecutedCommand(_ command: String) -> CommandHistoryEntry.ID? {
        let command = CommandHistoryEntry.normalizingLineContinuations(in: command)
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if command == commandExcludedFromHistory {
            commandExcludedFromHistory = nil
            return nil
        }
        return commandHistory.record(command)?.id
    }

    private func recordCommandCompletion(
        exitStatus: Int32, reportedDuration: TimeInterval?
    ) {
        guard let active = activeShellCommand else { return }
        activeShellCommand = nil
        guard let historyID = active.historyID else { return }
        commandHistory.recordCompletion(for: historyID, exitStatus: exitStatus, duration: reportedDuration)
    }

}

private final class SSHSessionRelay: @unchecked Sendable {
    weak var owner: SSHSessionModel?
}

// MARK: - Demo data

extension SSHSessionModel {
    /// A connected-looking session with a real terminal surface and synthetic,
    /// non-sensitive output. Screenshot mode uses this instead of opening a
    /// network connection or reading somebody's actual scrollback.
    static func demo(host: Host, transcript: String? = nil) -> SSHSessionModel {
        let sshSession = SSHSessionModel(host: host)
        sshSession.status = .connected
        sshSession.workingDirectory = "/var/log/nginx"
        sshSession.homeResolution = .resolved("/home/demo")
        sshSession.shellIntegrationAvailable = true
        sshSession.integratedShell = "zsh"
        sshSession.isShellPromptReady = true
        let bytes = Data((transcript ?? demoTranscript(for: host.name)).utf8)
        // Drive the same delegate callback that OSC 7 Shell Integration emits.
        // Feed the screen only after the native surface has mounted and sized;
        // writing into the default 80-column grid first leaves Ghostty's cursor
        // behind when a narrow demo pane reflows that content.
        Task { [weak sshSession] in
            try? await Task.sleep(for: .milliseconds(350))
            sshSession?.terminalSurface.receive(Data("\u{001B}[2J\u{001B}[H".utf8))
            sshSession?.terminalSurface.receive(bytes)
            // The demo has no remote PTY to synchronize Ghostty's interactive
            // cursor with received output. Hide that cursor for static captures
            // instead of advertising a caret at a position no shell reported.
            sshSession?.terminalSurface.receive(Data("\u{001B}[?25l".utf8))
            sshSession?.terminalState.terminalDidChangeWorkingDirectory("/var/log/nginx")
        }
        return sshSession
    }

    private static func demoTranscript(for host: String) -> String {
        let prompt =
            "\u{001B}[36mdeploy@\(host)\u{001B}[0m "
            + "\u{001B}[34m/var/log/nginx\u{001B}[0m %"
        return [
            "\u{001B}]7;file://\(host)/var/log/nginx\u{0007}",
            "\u{001B}[2mLast login: Thu Aug 27 16:42:18 from 10.0.0.12\u{001B}[0m",
            prompt + " systemctl status nginx --no-pager",
            "● nginx.service - A high performance web server",
            "     Loaded: loaded (/usr/lib/systemd/system/nginx.service; enabled)",
            "     Active: \u{001B}[32mactive (running)\u{001B}[0m since Thu 2026-08-27 09:14:03 UTC",
            prompt + " tail -n 3 access.log",
            "10.0.4.21 - - [27/Aug/2026:09:41:12] \"GET /health HTTP/1.1\" 200 18",
            "10.0.4.18 - - [27/Aug/2026:09:41:14] \"GET /api/status HTTP/1.1\" 200 52",
            prompt + " ",
        ].joined(separator: "\r\n")
    }

}
