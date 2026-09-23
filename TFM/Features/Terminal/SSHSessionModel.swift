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
    func sshSessionDidChangeRemoteWindowTitle(_ sshSession: SSHSessionModel)
    func closeSSHSessionPane(afterExit sshSession: SSHSessionModel)
}

/// One terminal sshSession inside a pane.
///
/// The screen buffer lives inside libghostty. This model bridges its in-memory
/// terminal backend to one SSH session and exposes connection state to SwiftUI.
@Observable
final class SSHSessionModel: Identifiable {
    let id = UUID()
    /// Never optional. Termind ships no local terminal — the App Sandbox has no
    /// route to a login shell worth having, and shipping a crippled one would be
    /// worse than shipping none — so a sshSession is always a sshSession *on* a host.
    var hostID: Host.ID
    var title: String
    var status: ConnectionStatus = .disconnected {
        didSet {
            statusStore?.setConnectionStatus(status, connectionID: id, hostID: hostID)
            if status.isLive != oldValue.isLive {
                inputRouter?.sshSessionDidChangeRemoteWindowTitle(self)
            }
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

    func displayPath(_ path: String) -> String {
        RemotePath.displayed(path, home: homeResolution)
    }
    var hasUnreadOutput: Bool = false
    /// History for an unsaved Quick Connect destination. Saved Hosts use the
    /// app-wide CommandHistoryModel instead so every window sees the same list.
    private(set) var transientCommandHistory: [CommandHistoryEntry] = []

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
    /// The most recent OSC 0/2 title reported by this SSH connection.
    ///
    /// Ghostty owns parsing and publishes the value through `TerminalViewState`.
    /// Keep a session-scoped copy here so reconnecting can discard a title from
    /// the old remote shell even though the long-lived terminal surface survives.
    private(set) var remoteWindowTitle: String? {
        didSet {
            guard remoteWindowTitle != oldValue else { return }
            inputRouter?.sshSessionDidChangeRemoteWindowTitle(self)
        }
    }
    var menuBarWindowTitle: String? {
        status.isLive ? remoteWindowTitle : nil
    }
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
    private(set) var commandGeneratorRevision: UInt64 = 0
    private let commandDraft = TerminalCommandDraftController()

    /// Non-nil while a connection is waiting for the user to approve a first or
    /// additional server fingerprint. No credential is sent before this clears.
    var pendingHostKey: SSHHostKeyPrompt? { connection.pendingHostKey }

    /// Set when this connection needs a login or credentials. The terminal view
    /// presents the editor; the sshSession remains disconnected until it receives
    /// either Continue or Continue and Save.
    var pendingAuthentication: SSHAuthenticationPrompt?
    let connection = RemoteSessionConnectionController()
    var connectionJourney: ConnectionJourney { connection.journey }

    private let terminalSurface: PersistentTerminalViewOwner
    var terminalState: TerminalViewState { terminalSurface.state }
    /// Owns the native terminal across SplitNode reparenting. Keeping this
    /// beside the sshSession makes the surface lifetime match the SSH sshSession,
    /// rather than the transient SwiftUI branch that currently displays it.
    var terminalViewOwner: PersistentTerminalViewOwner { terminalSurface }
    private weak var statusStore: (any RemoteSessionHostStore)?
    weak var commandHistoryStore: CommandHistoryModel?
    private var ssh: SSHPTYChannel?
    var connectionCoordinator: RemoteConnectionCoordinator?
    private var connectionTask: Task<Void, Never>?
    private var startsOnMount = true
    private(set) var connectionAttemptID: UUID?
    private var reconnectController: SessionReconnectController { connection.reconnect }
    private var workingDirectoryObservation: AnyCancellable?
    private var remoteWindowTitleObservation: AnyCancellable?
    /// The live terminal's frozen route and credential IDs. Password, Key, and
    /// passphrase material are resolved only for each attempted transfer
    /// connection and never retained here. Cleared with the SSH connection.
    private(set) var transferSnapshot: SSHAdditionalConnectionSnapshot?
    private var latestViewport = InMemoryTerminalViewport(columns: 80, rows: 24)
    var connectionRoute: SSHConnectionRoute?
    var connectionOrigin: RemoteConnectionOrigin = .library
    var isExternalTemporaryConnection: Bool { !connectionOrigin.allowsPersistence }
    private var transientHost: Host?
    private var usernameHint: String?
    private var suppliedAuthentications: [Host.ID: SSHAuthenticationSubmission] = [:]
    private var suppliedProxyAuthentications: [Host.ID: SSHProxyAuthenticationSubmission] = [:]
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
        self.transientHost = transientHost
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
        relay.owner = self
        observeWorkingDirectory(from: surface.state, through: relay)
        observeRemoteWindowTitle(from: surface.state, through: relay)
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
    }

    func requestCurrentDraft() async throws -> String {
        try await commandDraft.read(isAvailable: canGenerateFromCurrentDraft) { [weak self] data in
            self?.writeInputDirectly(data)
        }
    }

    /// Clears the shell's edit buffer through the installed line-editor widget,
    /// then inserts one literal command as a bracketed paste. There is
    /// intentionally no carriage return in this payload.
    func replaceCurrentDraft(with command: String) {
        writeInputDirectly(commandDraft.replacementPayload(for: command))
    }

    private func invalidateCommandGeneration() {
        commandGeneratorRevision &+= 1
        inputRouter?.sshSessionDidInvalidateCommandGeneration(self)
    }

    private func resetCommandGeneratorShellState() {
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
        startsOnMount = false
        startConnection(using: store)
    }

    private func startConnection(using store: any RemoteSessionHostStore) {
        resetCommandGeneratorShellState()
        remoteWindowTitle = nil
        homeResolution = .unavailable
        let reconnecting = connection.hasConnectedOnce && connection.isRecovering
        workingDirectory = nil
        transferSnapshot = nil
        commandExcludedFromHistory = nil
        statusStore = store
        let attemptID = UUID()
        connectionAttemptID = attemptID
        if let ssh { Task { await ssh.disconnect() } }
        ssh = nil
        guard let host = connectionHost(hostID, using: store) else {
            connection.stopRecovery()
            connectionAttemptID = nil
            status = .failed(String(localized: TermindCopy.Connections.theHostIsNoLongerAvailable))
            connectionJourney.fail(String(localized: TermindCopy.Connections.theHostIsNoLongerAvailable))
            return
        }
        isShellIntegrationEnabled = host.shellIntegrationMode.isEnabled(
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
            ?? identity?.username
            ?? usernameHint
        connectionJourney.begin(
            host: host, route: route, purpose: .sshSession, username: username,
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
            in: route, key: store.key
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
                                    publicKey: key.publicKey, certificate: key.certificate,
                                    passphraseOverride: suppliedAuthentication.passphraseForConnection(),
                                    requiresPassphrase: key.requiresPassphraseEntry,
                                    requiresUserPresence: key.requiresUserPresence
                                )
                            )
                        } else {
                            credentialFailures.append(
                                String(localized: TermindCopy.Terminal.theSelectedKeyHasNoSavedPrivateKey)
                            )
                        }
                    } catch {
                        credentialFailures.append(error.localizedDescription)
                    }
                } else {
                    credentialFailures.append(
                        String(localized: TermindCopy.Terminal.theSelectedKeyIsNoLongerAvailable)
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
                            String(localized: TermindCopy.Terminal.theSavedPasswordIsNoLongerAvailable)
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
                        && authenticationKeyID.flatMap { store.key($0) }?
                            .requiresPassphraseEntry == true
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
        keyID: SSHKeyRef.ID?, save: Bool,
        using store: any RemoteSessionHostStore
    ) {
        let selectedIdentity = identityID.flatMap { store.identity($0) }
        let trimmedUsername = ((pendingAuthentication?.isProxy == true ? nil : selectedIdentity?.username) ?? username)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else { return }
        guard let prompt = pendingAuthentication,
            var host = connectionHost(prompt.host.id, using: store)
        else { return }

        if prompt.isProxy {
            let submission = SSHProxyAuthenticationSubmission(
                username: trimmedUsername, password: password, identityID: selectedIdentity?.id)
            do {
                if save {
                    host = try store.saveProxyAuthentication(
                        submission, for: host, selectedIdentity: selectedIdentity,
                        suppliedPassword: password)
                }
                suppliedProxyAuthentications[host.id] = submission
                pendingAuthentication = nil
                connectionJourney.resume()
                connect(using: store)
            } catch {
                requestProxyAuthentication(
                    for: host, using: store, failureMessage: error.localizedDescription)
            }
            return
        }

        if prompt.requiresPassphrase,
            var staged = suppliedAuthentications[host.id]
        {
            guard let passphrase, !passphrase.isEmpty else { return }
            staged.passphrase = passphrase
            suppliedAuthentications[host.id] = staged
            pendingAuthentication = nil
            connectionJourney.resume()
            connect(using: store)
            return
        }

        let submittedKeyID = selectedIdentity?.keyID ?? keyID
        do {
            let submission = try store.authenticationSubmission(
                username: trimmedUsername, password: password, passphrase: passphrase,
                keyID: submittedKeyID, selectedIdentity: selectedIdentity
            )
            suppliedAuthentications[host.id] = submission
            if host.id == hostID { usernameHint = trimmedUsername }
            connectionRoute?.usernames[host.id] = trimmedUsername
            pendingAuthentication = nil
            connectionJourney.resume()

            if save {
                if let route = connectionRoute {
                    let saved = try store.saveConnectionRoute(
                        route, authentication: submission, authenticationHostID: host.id, suppliedPassword: password
                    )
                    adoptSavedRoute(saved, replacing: route, using: store)
                } else {
                    host = try store.saveAuthentication(
                        submission, for: host, selectedIdentity: selectedIdentity, suppliedPassword: password
                    )
                    if host.id == hostID { transientHost = host }
                }
            }
        } catch {
            requestAuthentication(
                for: host, username: trimmedUsername,
                selectedKeyID: submittedKeyID, failureMessage: error.localizedDescription,
                requiresPassphrase:
                    submittedKeyID.flatMap { store.key($0) }?.requiresPassphraseEntry == true
            )
            return
        }

        connect(using: store)
    }

    func trustAndConnect(_ observation: SSHHostKeyObservation, using store: any RemoteSessionHostStore) {
        connection.trustHostKey(observation, using: store)
    }

    func continueWithTemporaryHostKey(_ observation: SSHHostKeyObservation) {
        _ = connection.useTemporaryHostKey(observation)
    }

    func disconnect() {
        startsOnMount = false
        resetCommandGeneratorShellState()
        remoteWindowTitle = nil
        workingDirectory = nil
        homeResolution = .unavailable
        transferSnapshot = nil
        pendingInitialCommand = nil
        pendingConnectionStartupCommand = nil
        commandExcludedFromHistory = nil
        pendingAuthentication = nil
        suppliedAuthentications.removeAll()
        suppliedProxyAuthentications.removeAll()
        connectionAttemptID = nil
        connection.disconnect()
        connectionTask?.cancel()
        connectionTask = nil
        if let ssh { Task { await ssh.disconnect() } }
        ssh = nil
        status = .disconnected
    }

    func retryReconnectNow() {
        reconnectController.retryNow()
    }

    func stopReconnecting() {
        guard let reconnectState else { return }
        remoteWindowTitle = nil
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
        let configuration = SSHConnectionConfiguration(
            hostID: host.id, host: host.host, port: host.port, username: username,
            credentials: credentials, expectedHostKeys: expectedHostKeys,
            proxy: proxy, jumps: jumps,
            charset: host.charset,
            authenticationReference: authenticationReference
        )
        let terminalSurface = terminalSurface
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
        do {
            await actor.configureEnvironment(host.environmentVariables) { variables in
                let list = variables.joined(separator: ", ")
                let warning = String(localized: TermindCopy.Terminal.rejectedEnvironmentVariables(list))
                terminalSurface.receive(Data("\r\n⚠︎ \(warning)\r\n".utf8))
            }
            try await actor.connect(
                using: SSHConnectionRequest(
                    configuration: configuration,
                    authorizeHostKey: authorizeHostKey,
                    keyboardInteractive: { [weak self] challenge in
                        guard let self, await self.connectionAttemptID == attemptID else { throw CancellationError() }
                        return try await self.connection.answerKeyboardInteractive(challenge)
                    },
                    hostKeyConstraints: connectionOrigin.hostKeyConstraints
                ),
                shellIntegrationEnabled: isShellIntegrationEnabled,
                columns: latestViewport.columns, rows: latestViewport.rows,
                progress: progressHandler(attemptID: attemptID)
            )
            try Task.checkCancellation()
            guard connectionAttemptID == attemptID else { throw CancellationError() }
            transferSnapshot =
                statusStore?.additionalConnectionSnapshot(from: configuration)
                ?? SSHAdditionalConnectionSnapshot(configuration: configuration)
            suppliedAuthentications.removeAll()
            suppliedProxyAuthentications.removeAll()
            temporaryHostKeys.removeAll()
            _ = connection.markConnected()
            status = .connected
            if presentsConnectionJourney {
                connectionJourney.succeed()
            } else {
                connectionJourney.hide()
            }
            if wasReconnecting {
                appendTerminalNotice(
                    String(localized: TermindCopy.Terminal.reconnectedANewRemoteShellHasStarted)
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

    /// A normal remote-shell exit owns the pane lifecycle, not the reusable
    /// Ghostty surface lifecycle. Marking the in-memory backend as finished
    /// makes the surface permanently stop producing input, which is incorrect
    /// for Termind's retained pane model. Close the pane through its current
    /// Workspace instead; transport failures remain visible for reconnection.
    func handleRemoteExit(_ result: Result<Int32, TermindSSHError>) {
        resetCommandGeneratorShellState()
        remoteWindowTitle = nil
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
        appendTerminalNotice(String(localized: TermindCopy.Connections.connectionLostReconnectingProgress))
        scheduleReconnect(after: message, using: store)
    }

    private func scheduleReconnect(after message: String, using store: any RemoteSessionHostStore) {
        resetCommandGeneratorShellState()
        remoteWindowTitle = nil
        connectionAttemptID = nil
        connectionTask?.cancel()
        connectionTask = nil
        if let ssh { Task { await ssh.disconnect() } }
        ssh = nil
        transferSnapshot = nil
        status = .reconnecting
        let host = connectionHost(hostID, using: store)
        if let connectionRoute, let host {
            connectionJourney.begin(
                host: host, route: connectionRoute.hosts, purpose: .sshSession,
                username: connectionRoute.usernames[host.id], mode: .reconnection
            )
        } else {
            connection.presentReconnectJourney(
                host: host, using: store, purpose: .sshSession,
                username: host.flatMap { store.identity(for: $0)?.username } ?? usernameHint
            )
        }
        connection.scheduleRecovery(after: message) { [weak self, weak store] in
            guard let self, let store else { return }
            self.startConnection(using: store)
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

    private func progressHandler(attemptID: UUID) -> SSHRouteProgressHandler {
        connection.progressHandler(attemptID: attemptID) { [weak self] id in
            self?.connectionAttemptID == id
        }
    }

    func connectionHost(_ id: Host.ID, using store: any RemoteSessionHostStore) -> Host? {
        connectionRoute?.host(id) ?? store.host(id) ?? (id == hostID ? transientHost : nil)
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
        copy.connectionRoute = connectionRoute
        copy.connectionOrigin = connectionOrigin
        copy.connectionCoordinator = connectionCoordinator
        copy.commandHistoryStore = commandHistoryStore
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

    /// Ghostty parses OSC 7 and publishes the decoded remote path on its view
    /// state. Bridge that dependency-owned state into the sshSession so every Termind
    /// surface reads one observable source of truth.
    private func observeWorkingDirectory(
        from state: TerminalViewState,
        through relay: SSHSessionRelay
    ) {
        workingDirectoryObservation = state.$workingDirectory.sink { [weak relay] path in
            Task { @MainActor in
                relay?.owner?.workingDirectory = path?.isEmpty == false ? path : nil
            }
        }
    }

    /// Mirrors Ghostty's parsed OSC 0/2 title into the SSH connection's
    /// lifecycle. `TerminalViewState.title` deliberately outlives a transport;
    /// the copy does not, preventing a reconnected shell from inheriting the
    /// previous shell or foreground program's menu-bar title.
    private func observeRemoteWindowTitle(
        from state: TerminalViewState,
        through relay: SSHSessionRelay
    ) {
        remoteWindowTitleObservation = state.$title.sink { [weak relay] title in
            MainActor.assumeIsolated {
                relay?.owner?.remoteWindowTitle = RemoteWindowTitle.sanitized(title)
            }
        }
    }

    func receiveShellIntegrationEvent(_ event: SSHShellIntegrationEvent) {
        guard isShellIntegrationEnabled else { return }
        switch event {
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
        if statusStore?.host(hostID) != nil {
            return commandHistoryStore?.record(command, for: hostID)?.id
        } else {
            let entry = CommandHistoryEntry(hostID: hostID, command: command)
            transientCommandHistory.insert(entry, at: 0)
            if transientCommandHistory.count > CommandHistoryModel.perHostLimit {
                transientCommandHistory.removeLast(
                    transientCommandHistory.count - CommandHistoryModel.perHostLimit
                )
            }
            return entry.id
        }
    }

    private func recordCommandCompletion(
        exitStatus: Int32, reportedDuration: TimeInterval?
    ) {
        guard let active = activeShellCommand else { return }
        activeShellCommand = nil
        guard let historyID = active.historyID else { return }
        if statusStore?.host(hostID) != nil {
            commandHistoryStore?.recordCompletion(
                for: historyID, hostID: hostID,
                exitStatus: exitStatus, duration: reportedDuration
            )
        } else if let index = transientCommandHistory.firstIndex(where: {
            $0.id == historyID
        }) {
            transientCommandHistory[index].exitStatus = exitStatus
            transientCommandHistory[index].duration = reportedDuration
        }
    }

    func deleteTransientHistory(_ id: CommandHistoryEntry.ID) {
        transientCommandHistory.removeAll { $0.id == id }
    }

    func clearTransientHistory() {
        transientCommandHistory.removeAll()
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
