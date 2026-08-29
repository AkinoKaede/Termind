import Combine
import Foundation
import GhosttyTerminal
import GhosttyTheme

/// Marks the synchronous part of an AppKit terminal interaction.
///
/// Ghostty's in-memory backend uses one callback for everything written toward
/// the host: keyboard input, paste bytes, mouse reports, focus reports, and
/// terminal protocol replies. Broadcast Input must copy only the first two.
/// The native view enters this scope around keyboard/AppKit paste handling, and
/// the backend callback consumes its synchronous or short-lived deferred ticket
/// before hopping back to MainActor.
nonisolated final class TerminalInteractiveInputCapture: @unchecked Sendable {
    private static let deferredWriteWindowNanoseconds: UInt64 = 100_000_000
    private let lock = NSLock()
    private var depth = 0
    private var writeGeneration: UInt64 = 0
    private var deferredWriteDeadline: UInt64?

    var isActive: Bool {
        lock.withLock { depth > 0 }
    }

    func withInteraction<Result>(
        allowsDeferredWrite: Bool = true,
        _ operation: () throws -> Result
    ) rethrows -> Result {
        let generation = lock.withLock { () -> UInt64 in
            depth += 1
            return writeGeneration
        }
        defer {
            lock.withLock {
                depth -= 1
                guard allowsDeferredWrite, writeGeneration == generation else { return }
                deferredWriteDeadline =
                    DispatchTime.now().uptimeNanoseconds
                    &+ Self.deferredWriteWindowNanoseconds
            }
        }
        return try operation()
    }

    /// Classifies the backend callback while it still has the input event's
    /// provenance. Ordinarily Ghostty writes synchronously. The short-lived
    /// deferred ticket covers callbacks it schedules just after AppKit returns;
    /// it is consumed once and expires before unrelated terminal replies can be
    /// mistaken for user input.
    func classifyWrite() -> Bool {
        lock.withLock {
            writeGeneration &+= 1
            if depth > 0 {
                deferredWriteDeadline = nil
                return true
            }
            guard let deadline = deferredWriteDeadline,
                DispatchTime.now().uptimeNanoseconds <= deadline
            else {
                deferredWriteDeadline = nil
                return false
            }
            deferredWriteDeadline = nil
            return true
        }
    }
}

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

/// Search order follows Ghostty and VS Code's terminal find widget. A search
/// starts at the bottom of the buffer, so "previous" moves toward older output
/// and is the operation bound to Return and the upward arrow.
nonisolated enum TerminalFindDirection: String, Sendable {
    case previous
    case next

    var bindingAction: String { "navigate_search:\(rawValue)" }
}

nonisolated enum TerminalFindBinding {
    static func search(_ query: String) -> String { "search:\(query)" }
    static func navigate(_ direction: TerminalFindDirection) -> String {
        direction.bindingAction
    }
    static let end = "end_search"
}

nonisolated enum TerminalDraftError: LocalizedError, Sendable {
    case unavailable, alreadyPending, timedOut

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

/// One terminal sshSession inside a pane.
///
/// The screen buffer lives inside libghostty. This model bridges its in-memory
/// terminal backend to one libssh2 channel and exposes connection state to SwiftUI.
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
            statusStore?.setSSHSessionStatus(status, sshSessionID: id, hostID: hostID)
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
    private(set) var findQuery = ""
    private(set) var isFindPresented = false

    /// Whether the remote shell accepted OSC 133 integration.
    var shellIntegrationAvailable: Bool = false
    private(set) var integratedShell: String?
    private(set) var remoteSystemInfo: RemoteSystemInfo? {
        didSet {
            guard remoteSystemInfo != oldValue else { return }
            inputRouter?.sshSessionDidChangeRemoteSystemInfo(self)
        }
    }
    private(set) var isShellPromptReady = false
    private(set) var commandGeneratorRevision: UInt64 = 0
    private struct PendingDraftRequest {
        var id: UUID
        var continuation: CheckedContinuation<String, any Error>
    }
    private var pendingDraftRequest: PendingDraftRequest?
    private var draftRequestTimeoutTask: Task<Void, Never>?

    /// Non-nil while a connection is waiting for the user to approve a first or
    /// additional server fingerprint. No credential is sent before this clears.
    var pendingHostKey: SSHHostKeyPrompt?
    private var pendingHostKeyHostID: Host.ID?

    /// Set when this connection needs a login or credentials. The terminal view
    /// presents the editor; the sshSession remains disconnected until it receives
    /// either Continue or Continue and Save.
    var pendingAuthentication: SSHAuthenticationPrompt?
    let connection = RemoteSessionConnectionController()
    var connectionJourney: SSHConnectionJourney { connection.journey }

    let terminalState: TerminalViewState
    #if canImport(AppKit)
        /// Owns the native terminal across SplitNode reparenting. Keeping this
        /// beside the sshSession makes the surface lifetime match the SSH sshSession,
        /// rather than the transient SwiftUI branch that currently displays it.
        let terminalViewOwner: PersistentTerminalViewOwner
    #endif
    private let terminalBackend: InMemoryTerminalSession
    private weak var statusStore: (any RemoteSessionHostStore)?
    weak var commandHistoryStore: CommandHistoryModel?
    private var ssh: SSHSessionActor?
    var connectionCoordinator: RemoteConnectionCoordinator?
    private var connectionTask: Task<Void, Never>?
    private var connectionAttemptID: UUID?
    private var reconnectController: SessionReconnectController { connection.reconnect }
    private var hasConnectedOnce = false
    private var isRecoveringConnection = false
    private var workingDirectoryObservation: AnyCancellable?
    /// The exact authenticated route used by the live terminal, retained only
    /// in memory so a drop can open an independent SFTP connection without
    /// asking for credentials a second time. Cleared with the SSH connection.
    private(set) var transferConfiguration: SSHConnectionConfiguration?
    private var latestViewport = InMemoryTerminalViewport(columns: 80, rows: 24)
    private var transientHost: Host?
    private var usernameHint: String?
    private var suppliedAuthentications: [Host.ID: SSHAuthenticationSubmission] = [:]
    private var temporaryHostKeys: [Host.ID: SSHHostKeyIdentity] = [:]
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
    private var commandExcludedFromHistory: String?

    var reconnectState: ReconnectState? { connection.reconnectState }

    convenience init(hostID: Host.ID, title: String, initialCommand: String? = nil) {
        self.init(
            hostID: hostID, title: title, initialCommand: initialCommand,
            recordsInitialCommandInHistory: true
        )
    }

    init(
        hostID: Host.ID, title: String, initialCommand: String?,
        recordsInitialCommandInHistory: Bool
    ) {
        self.hostID = hostID
        self.title = title
        self.pendingInitialCommand = initialCommand.map {
            PendingInitialCommand(
                command: $0, recordsInHistory: recordsInitialCommandInHistory
            )
        }
        let relay = SSHSessionRelay()
        let backend = InMemoryTerminalSession(
            write: { data in
                let isInteractiveInput = relay.inputCapture.classifyWrite()
                Task { @MainActor in
                    relay.owner?.handleTerminalWrite(
                        data, isInteractiveInput: isInteractiveInput
                    )
                }
            },
            resize: { viewport in
                Task { @MainActor in relay.owner?.resizeSSH(viewport) }
            },
            suppressesPixelOnlyResizes: true
        )
        let state = TerminalViewState(configSource: .none)
        state.configuration = TerminalSurfaceOptions(
            backend: .inMemory(backend), resizeThrottleMilliseconds: 35
        )
        terminalBackend = backend
        terminalState = state
        #if canImport(AppKit)
            terminalViewOwner = PersistentTerminalViewOwner(
                state: state, inputCapture: relay.inputCapture
            )
        #endif
        relay.owner = self
        observeWorkingDirectory(from: state, through: relay)
    }

    convenience init(host: Host, usernameHint: String? = nil, initialCommand: String? = nil) {
        self.init(
            host: host, usernameHint: usernameHint, initialCommand: initialCommand,
            recordsInitialCommandInHistory: true
        )
    }

    init(
        host: Host, usernameHint: String? = nil, initialCommand: String?,
        recordsInitialCommandInHistory: Bool
    ) {
        self.transientHost = host
        self.usernameHint = usernameHint
        self.hostID = host.id
        self.title = host.name
        self.pendingInitialCommand = initialCommand.map {
            PendingInitialCommand(
                command: $0, recordsInHistory: recordsInitialCommandInHistory
            )
        }
        let relay = SSHSessionRelay()
        let backend = InMemoryTerminalSession(
            write: { data in
                let isInteractiveInput = relay.inputCapture.classifyWrite()
                Task { @MainActor in
                    relay.owner?.handleTerminalWrite(
                        data, isInteractiveInput: isInteractiveInput
                    )
                }
            },
            resize: { viewport in
                Task { @MainActor in relay.owner?.resizeSSH(viewport) }
            },
            suppressesPixelOnlyResizes: true
        )
        let state = TerminalViewState(configSource: .none)
        state.configuration = TerminalSurfaceOptions(
            backend: .inMemory(backend), resizeThrottleMilliseconds: 35
        )
        terminalBackend = backend
        terminalState = state
        #if canImport(AppKit)
            terminalViewOwner = PersistentTerminalViewOwner(
                state: state, inputCapture: relay.inputCapture
            )
        #endif
        relay.owner = self
        observeWorkingDirectory(from: state, through: relay)
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
        transferConfiguration
    }

    func requestTerminalFocus() {
        #if canImport(AppKit)
            terminalViewOwner.requestFocus()
        #else
            terminalState.requestFocus()
        #endif
    }

    /// Opens or refocuses the find bar. Reopening a dismissed query starts the
    /// Ghostty search again; pressing ⌘F while it is already open only refocuses
    /// the field and does not reset the current match.
    func presentFind() {
        let wasPresented = isFindPresented
        isFindPresented = true
        if !wasPresented, !findQuery.isEmpty {
            performFindBinding(TerminalFindBinding.search(findQuery))
        }
    }

    func updateFindQuery(_ query: String) {
        guard findQuery != query else { return }
        findQuery = query
        performFindBinding(TerminalFindBinding.search(query))
    }

    func navigateFind(_ direction: TerminalFindDirection) {
        guard isFindPresented, !findQuery.isEmpty else { return }
        performFindBinding(TerminalFindBinding.navigate(direction))
    }

    /// Used by ⌘G/F3: VS Code reveals the find widget when navigation is invoked
    /// from the terminal, then moves only when there is a retained query.
    func presentFindAndNavigate(_ direction: TerminalFindDirection) {
        presentFind()
        navigateFind(direction)
    }

    func dismissFind() {
        guard isFindPresented else { return }
        performFindBinding(TerminalFindBinding.end)
        isFindPresented = false
        requestTerminalFocus()
    }

    private func performFindBinding(_ action: String) {
        #if canImport(AppKit)
            terminalViewOwner.performBindingAction(action)
        #endif
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
        status.isLive && shellIntegrationAvailable && isShellPromptReady
            && Self.supportedGeneratorShells.contains(integratedShell ?? "")
    }

    func requestCurrentDraft() async throws -> String {
        guard canGenerateFromCurrentDraft else { throw TerminalDraftError.unavailable }
        guard pendingDraftRequest == nil else { throw TerminalDraftError.alreadyPending }
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, any Error>) in
                pendingDraftRequest = PendingDraftRequest(
                    id: requestID, continuation: continuation
                )
                writeInputDirectly(Self.commandGeneratorDraftRequest)
                draftRequestTimeoutTask?.cancel()
                draftRequestTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    self?.failDraftRequest(id: requestID, with: TerminalDraftError.timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.failDraftRequest(id: requestID, with: CancellationError())
            }
        }
    }

    /// Clears the shell's edit buffer through the installed line-editor widget,
    /// then inserts one literal command as a bracketed paste. There is
    /// intentionally no carriage return in this payload.
    func replaceCurrentDraft(with command: String) {
        var data = Self.commandGeneratorDraftClear
        data.append(Self.bracketedPasteStart)
        data.append(Data(command.utf8))
        data.append(Self.bracketedPasteEnd)
        writeInputDirectly(data)
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

    private func invalidateCommandGeneration() {
        commandGeneratorRevision &+= 1
        inputRouter?.sshSessionDidInvalidateCommandGeneration(self)
    }

    private func resetCommandGeneratorShellState() {
        integratedShell = nil
        remoteSystemInfo = nil
        isShellPromptReady = false
        shellIntegrationAvailable = false
        if let request = pendingDraftRequest {
            failDraftRequest(id: request.id, with: TerminalDraftError.unavailable)
        }
        invalidateCommandGeneration()
    }

    func applyShellIntegrationPreference(isEnabled: Bool) {
        guard !isEnabled else { return }
        remoteSystemInfo = nil
    }

    private static let supportedGeneratorShells: Set<String> = ["bash", "zsh", "fish"]
    private static let commandGeneratorDraftRequest = Data("\u{1B}[777;1~".utf8)
    private static let commandGeneratorDraftClear = Data("\u{1B}[777;2~".utf8)
    private static let bracketedPasteStart = Data("\u{1B}[200~".utf8)
    private static let bracketedPasteEnd = Data("\u{1B}[201~".utf8)

    func connect(using store: any RemoteSessionHostStore) {
        startConnection(using: store)
    }

    private func startConnection(using store: any RemoteSessionHostStore) {
        resetCommandGeneratorShellState()
        let reconnecting = hasConnectedOnce && isRecoveringConnection
        workingDirectory = nil
        transferConfiguration = nil
        commandExcludedFromHistory = nil
        statusStore = store
        let attemptID = UUID()
        connectionAttemptID = attemptID
        if let ssh { Task { await ssh.disconnect() } }
        ssh = nil
        guard let host = store.host(hostID) ?? transientHost else {
            reconnectController.stop()
            isRecoveringConnection = false
            pendingInitialCommand = nil
            connectionAttemptID = nil
            status = .failed(String(localized: "The host is no longer available."))
            connectionJourney.fail(String(localized: "The host is no longer available."))
            return
        }
        let route = store.route(for: host)
        let identity = store.identity(for: host)
        let suppliedAuthentication = suppliedAuthentications[host.id]
        let username =
            suppliedAuthentication?.username
            ?? identity?.username
            ?? usernameHint
        connectionJourney.begin(
            host: host, route: route, purpose: .sshSession, username: username,
            mode: reconnecting ? .reconnection : .connection
        )
        if let passphraseHost = route.first(where: { routeHost in
            guard let submission = suppliedAuthentications[routeHost.id],
                submission.passphrase == nil,
                let keyID = submission.keyID,
                let key = store.key(keyID)
            else { return false }
            return key.requiresPassphraseEntry
        }), let submission = suppliedAuthentications[passphraseHost.id] {
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
                || suppliedAuthentication.password != nil
            if let keyID = suppliedAuthentication.keyID {
                if let key = store.key(keyID) {
                    do {
                        if let credential = try store.keyCredential(for: key) {
                            credentials.append(
                                credential.sshCredential(
                                    publicKey: key.publicKey, certificate: key.certificate,
                                    passphraseOverride: suppliedAuthentication.passphrase
                                )
                            )
                        } else {
                            credentialFailures.append(
                                String(localized: "The selected key has no saved private key.")
                            )
                        }
                    } catch {
                        credentialFailures.append(error.localizedDescription)
                    }
                } else {
                    credentialFailures.append(
                        String(localized: "The selected key is no longer available.")
                    )
                }
            }
            if let password = suppliedAuthentication.password {
                credentials.append(.password(password))
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
        if credentials.isEmpty, suppliedAuthentication == nil {
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
        do {
            proxy = try store.transportProxy(for: host)
            jumps = try store.sshJumpConfigurations(
                for: host, submissions: suppliedAuthentications,
                temporaryHostKeys: temporaryHostKeys
            )
        } catch {
            if let sshError = error as? TermindSSHError,
                sshError.shouldRequestHostKey,
                let id = sshError.routeHostID,
                let jump = store.host(id)
            {
                status = reconnecting ? .reconnecting : .connecting
                connectionTask = Task { [weak self] in
                    await self?.discoverHostKey(
                        for: jump, using: store, attemptID: attemptID
                    )
                }
                return
            }
            if let sshError = error as? TermindSSHError,
                sshError.shouldRequestAuthentication,
                let id = sshError.routeHostID,
                let jump = store.host(id)
            {
                let identity = store.identity(for: jump)
                let submitted = suppliedAuthentications[jump.id]
                let retryNeedsPassphrase = submitted?.passphrase == nil
                    && (submitted?.keyID ?? identity?.keyID)
                        .flatMap { store.key($0) }?.requiresPassphraseEntry == true
                connectionAttemptID = nil
                requestAuthentication(
                    for: jump, username: identity?.username ?? "",
                    selectedKeyID: submitted?.keyID ?? identity?.keyID,
                    failureMessage: sshError.localizedDescription,
                    requiresPassphrase: retryNeedsPassphrase,
                    preserveSubmission: retryNeedsPassphrase && submitted != nil
                )
                return
            }
            pendingInitialCommand = nil
            connectionAttemptID = nil
            handleConnectionAttemptFailure(
                error, store: store, reconnecting: reconnecting
            )
            return
        }

        pendingHostKey = nil
        connectionTask?.cancel()
        status = reconnecting ? .reconnecting : .connecting
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let observation = try await SSHSessionActor.discoverHostKey(
                    hostID: host.id, host: host.host, port: host.port,
                    proxy: proxy, jumps: jumps, progress: progressHandler(attemptID: attemptID)
                )
                try Task.checkCancellation()
                guard connectionAttemptID == attemptID else { throw CancellationError() }
                let expectedHostKeys: Set<SSHHostKeyIdentity>
                do {
                    expectedHostKeys = try store.expectedHostKeys(
                        for: host, temporaryHostKeys: temporaryHostKeys
                    )
                } catch TermindSSHError.untrustedHost {
                    presentHostKeyPrompt(
                        observation, kind: .firstUse, hostID: host.id
                    )
                    return
                }
                guard expectedHostKeys.contains(observation.identity) else {
                    store.markKnownHostMismatched(hostname: host.host, port: host.port)
                    presentHostKeyPrompt(
                        observation,
                        kind: .additionalKey(trustedKeyCount: store.knownHosts(for: host).count),
                        hostID: host.id
                    )
                    return
                }
                try await openSSH(
                    host: host, username: username, credentials: credentials,
                    expectedHostKeys: expectedHostKeys, proxy: proxy, jumps: jumps,
                    attemptID: attemptID
                )
            } catch is CancellationError {
                guard connectionAttemptID == attemptID else { return }
                connectionAttemptID = nil
                status = .disconnected
            } catch {
                guard connectionAttemptID == attemptID else { return }
                connectionAttemptID = nil
                if let sshError = error as? TermindSSHError, sshError.isHostKeyChanged {
                    store.markKnownHostMismatched(hostname: host.host, port: host.port)
                    connectionAttemptID = attemptID
                    connectionTask = Task { [weak self] in
                        await self?.discoverHostKey(
                            for: host, using: store, attemptID: attemptID
                        )
                    }
                } else if let sshError = error as? TermindSSHError,
                    sshError.shouldRequestHostKey,
                    let id = sshError.routeHostID,
                    let jump = store.host(id)
                {
                    connectionAttemptID = attemptID
                    connectionTask = Task { [weak self] in
                        await self?.discoverHostKey(
                            for: jump, using: store, attemptID: attemptID
                        )
                    }
                } else if let sshError = error as? TermindSSHError,
                    sshError.shouldRequestAuthentication
                {
                    let authenticationHost: Host
                    if let id = sshError.routeHostID, let jump = store.host(id) {
                        authenticationHost = jump
                    } else {
                        authenticationHost = host
                    }
                    let authenticationIdentity = store.identity(for: authenticationHost)
                    let submitted = suppliedAuthentications[authenticationHost.id]
                    let authenticationKeyID = submitted?.keyID
                        ?? authenticationIdentity?.keyID ?? selectedKeyID
                    let retryNeedsPassphrase = submitted?.passphrase == nil
                        && authenticationKeyID.flatMap { store.key($0) }?
                            .requiresPassphraseEntry == true
                    let returnsToIdentity = submitted?.passphrase != nil
                    requestAuthentication(
                        for: authenticationHost,
                        username: authenticationIdentity?.username ?? username,
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
        let trimmedUsername = (selectedIdentity?.username ?? username)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else { return }
        guard let prompt = pendingAuthentication,
            var host = store.host(prompt.host.id) ?? (prompt.host.id == hostID ? transientHost : nil)
        else { return }

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
        let submittedPassword: String?
        do {
            submittedPassword =
                try password
                ?? selectedIdentity.flatMap {
                    try store.passwordCredential(for: $0)
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

        suppliedAuthentications[host.id] = SSHAuthenticationSubmission(
            username: trimmedUsername, password: submittedPassword,
            passphrase: passphrase, keyID: submittedKeyID,
            identityID: selectedIdentity?.id
        )
        if host.id == hostID { usernameHint = trimmedUsername }
        pendingAuthentication = nil
        connectionJourney.resume()

        if save {
            if let selectedIdentity {
                if let password {
                    do {
                        try store.upsert(
                            selectedIdentity, passwordUpdate: .replace(password)
                        )
                    } catch {
                        requestAuthentication(
                            for: host, username: trimmedUsername,
                            selectedKeyID: submittedKeyID,
                            failureMessage: error.localizedDescription,
                            requiresPassphrase:
                                submittedKeyID
                                .flatMap { store.key($0) }?.requiresPassphraseEntry == true
                        )
                        return
                    }
                }
                host.identityID = selectedIdentity.id
                store.upsert(host)
                if host.id == hostID { transientHost = host }
                connect(using: store)
                return
            }
            let existing = store.identity(for: host)
            let identity = Identity(
                id: existing?.id ?? UUID(),
                name: existing?.name ?? trimmedUsername,
                username: trimmedUsername,
                credentialRef: existing?.credentialRef ?? "",
                passwordStorage: existing?.passwordStorage ?? .iCloud,
                keyID: submittedKeyID,
                notes: existing?.notes ?? "",
                lastUsedAt: existing?.lastUsedAt
            )
            let passwordUpdate: IdentityPasswordUpdate =
                submittedPassword.map(
                    IdentityPasswordUpdate.replace
                ) ?? (existing == nil ? .remove : .keep)
            do {
                try store.upsert(identity, passwordUpdate: passwordUpdate)
            } catch {
                requestAuthentication(
                    for: host, username: trimmedUsername,
                    selectedKeyID: submittedKeyID, failureMessage: error.localizedDescription,
                    requiresPassphrase:
                        submittedKeyID
                        .flatMap { store.key($0) }?.requiresPassphraseEntry == true
                )
                return
            }
            host.identityID = identity.id
            store.upsert(host)
            if host.id == hostID { transientHost = host }
        }
        connect(using: store)
    }

    func trustAndConnect(_ observation: SSHHostKeyObservation, using store: any RemoteSessionHostStore) {
        store.trust(
            KnownHostEntry(
                hostname: observation.hostname, port: observation.port,
                algorithm: observation.algorithm, fingerprint: observation.fingerprint,
                addedAt: Date()
            ))
        if let pendingHostKeyHostID {
            temporaryHostKeys[pendingHostKeyHostID] = nil
        }
        pendingHostKey = nil
        pendingHostKeyHostID = nil
        connectionJourney.resume()
        connect(using: store)
    }

    func continueWithTemporaryHostKey(
        _ observation: SSHHostKeyObservation, using store: any RemoteSessionHostStore
    ) {
        guard let hostID = pendingHostKeyHostID else { return }
        temporaryHostKeys[hostID] = observation.identity
        pendingHostKey = nil
        pendingHostKeyHostID = nil
        connectionJourney.resume()
        connect(using: store)
    }

    func disconnect() {
        resetCommandGeneratorShellState()
        workingDirectory = nil
        transferConfiguration = nil
        pendingInitialCommand = nil
        commandExcludedFromHistory = nil
        pendingAuthentication = nil
        pendingHostKey = nil
        pendingHostKeyHostID = nil
        suppliedAuthentications.removeAll()
        temporaryHostKeys.removeAll()
        connectionAttemptID = nil
        reconnectController.stop()
        hasConnectedOnce = false
        isRecoveringConnection = false
        connectionTask?.cancel()
        connectionTask = nil
        if let ssh { Task { await ssh.disconnect() } }
        ssh = nil
        status = .disconnected
        connectionJourney.hide()
    }

    func retryReconnectNow() {
        reconnectController.retryNow()
    }

    func stopReconnecting() {
        guard let reconnectState else { return }
        reconnectController.stop()
        isRecoveringConnection = false
        connectionAttemptID = nil
        connectionTask?.cancel()
        connectionTask = nil
        if let ssh { Task { await ssh.disconnect() } }
        ssh = nil
        status = .failed(reconnectState.lastError)
        connectionJourney.fail(reconnectState.lastError)
    }

    func applyAppearance(_ preferences: TerminalAppearancePreferences) {
        let light = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: preferences.lightThemeName,
            customEnabled: preferences.lightCustomEnabled,
            customText: preferences.lightCustomConfiguration,
            isDark: false
        )
        let dark = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: preferences.darkThemeName,
            customEnabled: preferences.darkCustomEnabled,
            customText: preferences.darkCustomConfiguration,
            isDark: true
        )
        terminalState.setTheme(GhosttyTerminal.TerminalTheme(light: light, dark: dark))
        terminalState.setTerminalConfiguration(
            TerminalConfiguration { builder in
                if !preferences.fontFollowTheme {
                    builder.withFontSize(Float(preferences.fontSize))
                }
                builder.withWindowPaddingX(Int(Metrics.Space.m))
                builder.withWindowPaddingY(Int(Metrics.Space.m))
            }
        )
    }

    private func openSSH(
        host: Host, username: String, credentials: [SSHCredentials],
        expectedHostKeys: Set<SSHHostKeyIdentity>,
        proxy: SSHTransportProxy?, jumps: [SSHRouteHopConfiguration],
        attemptID: UUID
    ) async throws {
        let wasReconnecting = isRecoveringConnection
        let presentsConnectionJourney = connectionJourney.isPresented
        let configuration = SSHConnectionConfiguration(
            hostID: host.id, host: host.host, port: host.port, username: username,
            credentials: credentials, expectedHostKeys: expectedHostKeys,
            proxy: proxy, jumps: jumps
        )
        let backend = terminalBackend
        let actor = (connectionCoordinator ?? RemoteConnectionCoordinator()).makeSSHSession(
            output: { data in backend.receive(data) },
            exit: { [weak self] result in
                Task { @MainActor in
                    guard let self, self.connectionAttemptID == attemptID else { return }
                    self.handleRemoteExit(result)
                }
            },
            shellIntegration: { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    self.receiveShellIntegrationEvent(event)
                }
            }
        )
        ssh = actor
        do {
            try await actor.connect(
                hostID: configuration.hostID, host: configuration.host,
                port: configuration.port, username: configuration.username,
                credentials: configuration.credentials,
                expectedHostKeys: configuration.expectedHostKeys,
                proxy: configuration.proxy, jumps: configuration.jumps,
                shellIntegrationEnabled: SettingsKey.isShellIntegrationEnabled,
                columns: latestViewport.columns, rows: latestViewport.rows,
                progress: progressHandler(attemptID: attemptID)
            )
            try Task.checkCancellation()
            guard connectionAttemptID == attemptID else { throw CancellationError() }
            transferConfiguration = configuration
            suppliedAuthentications.removeAll()
            temporaryHostKeys.removeAll()
            let initialConnection = !hasConnectedOnce
            hasConnectedOnce = true
            isRecoveringConnection = false
            reconnectController.markConnected(initial: initialConnection)
            status = .connected
            if presentsConnectionJourney {
                connectionJourney.succeed()
            } else {
                connectionJourney.hide()
            }
            if wasReconnecting {
                appendTerminalNotice(
                    String(localized: "Reconnected; a new remote shell has started.")
                )
            }
            submitPendingInitialCommand()
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
        workingDirectory = nil
        transferConfiguration = nil
        connectionAttemptID = nil
        ssh = nil
        switch result {
        case .success:
            reconnectController.stop()
            hasConnectedOnce = false
            isRecoveringConnection = false
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
        if hasConnectedOnce || reconnecting {
            scheduleReconnect(after: error.localizedDescription, using: store)
        } else {
            pendingInitialCommand = nil
            status = .failed(error.localizedDescription)
            connectionJourney.fail(
                error.localizedDescription, at: routeHostID(from: error)
            )
        }
    }

    private func beginAutomaticReconnect(after message: String) {
        guard hasConnectedOnce, let store = statusStore else {
            status = .failed(message)
            return
        }
        appendTerminalNotice(String(localized: "Connection lost; reconnecting…"))
        isRecoveringConnection = true
        scheduleReconnect(after: message, using: store)
    }

    private func scheduleReconnect(after message: String, using store: any RemoteSessionHostStore) {
        resetCommandGeneratorShellState()
        isRecoveringConnection = true
        connectionAttemptID = nil
        connectionTask?.cancel()
        connectionTask = nil
        if let ssh { Task { await ssh.disconnect() } }
        ssh = nil
        transferConfiguration = nil
        status = .reconnecting
        presentReconnectJourney(using: store)
        reconnectController.schedule(after: message) { [weak self, weak store] in
            guard let self, let store else { return }
            self.startConnection(using: store)
        }
    }

    private func presentReconnectJourney(using store: any RemoteSessionHostStore) {
        guard let host = store.host(hostID) ?? transientHost else { return }
        connectionJourney.begin(
            host: host, route: store.route(for: host), purpose: .sshSession,
            username: store.identity(for: host)?.username ?? usernameHint,
            mode: .reconnection
        )
    }

    private func appendTerminalNotice(_ message: String) {
        terminalBackend.receive(Data("\r\n\u{001B}[2m[Termind] \(message)\u{001B}[0m\r\n".utf8))
    }

    private func requestAuthentication(
        for host: Host, username: String,
        selectedKeyID: SSHKeyRef.ID?, failureMessage: String? = nil,
        requiresPassphrase: Bool = false,
        mode: SSHAuthenticationPrompt.Mode = .localIdentity,
        preserveSubmission: Bool = false
    ) {
        reconnectController.pauseForUserInteraction()
        if !preserveSubmission { suppliedAuthentications[host.id] = nil }
        pendingAuthentication = SSHAuthenticationPrompt(
            host: host,
            selectedIdentityID: preserveSubmission
                ? suppliedAuthentications[host.id]?.identityID : host.identityID,
            username: username,
            selectedKeyID: selectedKeyID,
            failureMessage: failureMessage?.isEmpty == false ? failureMessage : nil,
            requiresPassphrase: requiresPassphrase, mode: mode
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

    private func progressHandler(attemptID: UUID) -> SSHRouteProgressHandler {
        { [weak self] event in
            Task { @MainActor in
                guard let self, self.connectionAttemptID == attemptID else { return }
                self.connectionJourney.receive(event)
            }
        }
    }

    private func routeHostID(from error: any Error) -> Host.ID? {
        (error as? TermindSSHError)?.routeHostID
    }

    private func discoverHostKey(
        for host: Host, using store: any RemoteSessionHostStore, attemptID: UUID
    ) async {
        do {
            let observation = try await SSHSessionActor.discoverHostKey(
                hostID: host.id, host: host.host, port: host.port,
                proxy: try store.transportProxy(for: host),
                jumps: try store.sshJumpConfigurations(
                    for: host, submissions: suppliedAuthentications,
                    temporaryHostKeys: temporaryHostKeys
                ),
                progress: progressHandler(attemptID: attemptID)
            )
            guard connectionAttemptID == attemptID else { return }
            let trusted = Set(store.knownHosts(for: host).map(\.identity))
            if trusted.contains(observation.identity) {
                connect(using: store)
                return
            }
            let kind: SSHHostKeyPrompt.Kind
            if trusted.isEmpty {
                kind = .firstUse
            } else {
                store.markKnownHostMismatched(hostname: host.host, port: host.port)
                kind = .additionalKey(trustedKeyCount: trusted.count)
            }
            presentHostKeyPrompt(observation, kind: kind, hostID: host.id)
        } catch {
            guard connectionAttemptID == attemptID else { return }
            connectionAttemptID = nil
            if hasConnectedOnce {
                scheduleReconnect(after: error.localizedDescription, using: store)
            } else {
                status = .failed(error.localizedDescription)
                connectionJourney.fail(error.localizedDescription, at: host.id)
            }
        }
    }

    private func presentHostKeyPrompt(
        _ observation: SSHHostKeyObservation, kind: SSHHostKeyPrompt.Kind, hostID: Host.ID
    ) {
        reconnectController.pauseForUserInteraction()
        pendingHostKey = SSHHostKeyPrompt(observation: observation, kind: kind)
        pendingHostKeyHostID = hostID
        connectionAttemptID = nil
        status = .disconnected
        connectionJourney.waitForHostKey(
            at: hostID, fingerprint: observation.fingerprint
        )
    }

    func copyForReconnect() -> SSHSessionModel {
        let host = transientHost ?? Host(id: hostID, name: title, host: title)
        let copy = SSHSessionModel(host: host, usernameHint: usernameHint)
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

    func receiveShellIntegrationEvent(_ event: SSHShellIntegrationEvent) {
        switch event {
        case .available(let shell, let systemInfo):
            integratedShell = shell
            remoteSystemInfo = systemInfo
            isShellPromptReady = false
            shellIntegrationAvailable = true
            invalidateCommandGeneration()
        case .promptReady:
            isShellPromptReady = true
            invalidateCommandGeneration()
        case .commandStarted(let command):
            isShellPromptReady = false
            invalidateCommandGeneration()
            recordExecutedCommand(command)
        case .draft(let draft):
            completeDraftRequest(with: draft)
        }
    }

    /// Submits the one-shot startup command. Keeping the History exclusion next
    /// to the write ensures it is armed only when the command actually runs.
    func submitPendingInitialCommand() {
        guard let initialCommand = pendingInitialCommand else { return }
        pendingInitialCommand = nil
        if !initialCommand.recordsInHistory {
            commandExcludedFromHistory = initialCommand.command
        }
        insert(initialCommand.command, submit: true)
    }

    func recordExecutedCommand(_ command: String) {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if command == commandExcludedFromHistory {
            commandExcludedFromHistory = nil
            return
        }
        if statusStore?.host(hostID) != nil {
            commandHistoryStore?.record(command, for: hostID)
        } else {
            transientCommandHistory.insert(
                CommandHistoryEntry(hostID: hostID, command: command), at: 0
            )
            if transientCommandHistory.count > CommandHistoryModel.perHostLimit {
                transientCommandHistory.removeLast(
                    transientCommandHistory.count - CommandHistoryModel.perHostLimit
                )
            }
        }
    }

    func deleteTransientHistory(_ id: CommandHistoryEntry.ID) {
        transientCommandHistory.removeAll { $0.id == id }
    }

    func clearTransientHistory() {
        transientCommandHistory.removeAll()
    }
}

nonisolated struct SSHAuthenticationPrompt: Identifiable, Hashable, Sendable {
    nonisolated enum Mode: Hashable, Sendable {
        case localIdentity
        case serverChallenge
    }

    let id = UUID()
    var host: Host
    var selectedIdentityID: Identity.ID? = nil
    var username: String
    var selectedKeyID: SSHKeyRef.ID?
    var failureMessage: String?
    var requiresPassphrase = false
    var mode: Mode = .localIdentity
}

private final class SSHSessionRelay: @unchecked Sendable {
    weak var owner: SSHSessionModel?
    let inputCapture = TerminalInteractiveInputCapture()
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
            sshSession?.terminalBackend.receive(Data("\u{001B}[2J\u{001B}[H".utf8))
            sshSession?.terminalBackend.receive(bytes)
            // The demo has no remote PTY to synchronize Ghostty's interactive
            // cursor with received output. Hide that cursor for static captures
            // instead of advertising a caret at a position no shell reported.
            sshSession?.terminalBackend.receive(Data("\u{001B}[?25l".utf8))
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
