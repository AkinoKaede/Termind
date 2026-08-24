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
    func sshSession(
        _ sshSession: SSHSessionModel,
        didChangeWorkingDirectory workingDirectory: String?
    )
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

/// The UI state belongs to the sshSession, not the transient SwiftUI pane that is
/// currently mounting it. Moving a terminal between panes therefore moves its
/// open find bar and retained query with the scrollback they search.
nonisolated struct TerminalFindState: Equatable, Sendable {
    var query = ""
    var isPresented = false
    var focusRequest: UInt64 = 0

    mutating func present() {
        isPresented = true
        focusRequest &+= 1
    }

    mutating func dismiss() {
        isPresented = false
    }
}

nonisolated enum TerminalFindBinding {
    static func search(_ query: String) -> String { "search:\(query)" }
    static func navigate(_ direction: TerminalFindDirection) -> String {
        direction.bindingAction
    }
    static let end = "end_search"
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
            inputRouter?.sshSession(
                self, didChangeWorkingDirectory: workingDirectory
            )
        }
    }
    var latencyMilliseconds: Int?
    var hasUnreadOutput: Bool = false

    /// Find stays with this terminal's scrollback. Closing the bar ends Ghostty's
    /// highlights but deliberately retains the query, matching VS Code when ⌘F
    /// is used again in the same terminal.
    var find = TerminalFindState()

    /// Whether the remote shell accepted OSC 133 integration. When false the
    /// inline suggestion overlay stays hidden — it has no way to know where the
    /// prompt is — and the AI Context Panel is the only surface. This flag exists
    /// from P0 so the degraded path is never an afterthought.
    var shellIntegrationAvailable: Bool = false

    /// The one command currently floating above the prompt, if any.
    var inlineSuggestion: SuggestedCommand?

    /// Non-nil while a connection is waiting for the user to approve a first or
    /// additional server fingerprint. No credential is sent before this clears.
    var pendingHostKey: SSHHostKeyPrompt?
    private var pendingHostKeyHostID: Host.ID?

    /// Set when this connection needs a login or credentials. The terminal view
    /// presents the editor; the sshSession remains disconnected until it receives
    /// either Continue or Continue and Save.
    var pendingAuthentication: SSHAuthenticationPrompt?
    let connectionJourney = SSHConnectionJourney()

    let terminalState: TerminalViewState
    #if canImport(AppKit)
        /// Owns the native terminal across SplitNode reparenting. Keeping this
        /// beside the sshSession makes the surface lifetime match the SSH sshSession,
        /// rather than the transient SwiftUI branch that currently displays it.
        let terminalViewOwner: PersistentTerminalViewOwner
    #endif
    private let terminalBackend: InMemoryTerminalSession
    private weak var statusStore: HostStore?
    private var ssh: SSHSessionActor?
    var connectionCoordinator: RemoteConnectionCoordinator?
    private var connectionTask: Task<Void, Never>?
    private var connectionAttemptID: UUID?
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
    /// A Snippet-launched sshSession submits this once, after the first successful
    /// connection. Authentication and host-key prompts keep it alive; failure,
    /// cancellation, or an explicit disconnect consumes it without running.
    private var pendingInitialCommand: String?

    init(hostID: Host.ID, title: String, initialCommand: String? = nil) {
        self.hostID = hostID
        self.title = title
        self.pendingInitialCommand = initialCommand
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

    init(host: Host, usernameHint: String? = nil, initialCommand: String? = nil) {
        self.transientHost = host
        self.usernameHint = usernameHint
        self.hostID = host.id
        self.title = host.name
        self.pendingInitialCommand = initialCommand
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

    var canShowInlineSuggestions: Bool {
        shellIntegrationAvailable && status.isLive
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
        let wasPresented = find.isPresented
        find.present()
        if !wasPresented, !find.query.isEmpty {
            performFindBinding(TerminalFindBinding.search(find.query))
        }
    }

    func updateFindQuery(_ query: String) {
        guard find.query != query else { return }
        find.query = query
        performFindBinding(TerminalFindBinding.search(query))
    }

    func navigateFind(_ direction: TerminalFindDirection) {
        guard find.isPresented, !find.query.isEmpty else { return }
        performFindBinding(TerminalFindBinding.navigate(direction))
    }

    /// Used by ⌘G/F3: VS Code reveals the find widget when navigation is invoked
    /// from the terminal, then moves only when there is a retained query.
    func presentFindAndNavigate(_ direction: TerminalFindDirection) {
        presentFind()
        navigateFind(direction)
    }

    func dismissFind() {
        guard find.isPresented else { return }
        performFindBinding(TerminalFindBinding.end)
        find.dismiss()
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
    /// snippet, an AI command card, and the inline suggestion. One choke point
    /// makes broadcast possible — see `Workspace.deliver`; `submit` appends the
    /// newline that the user's own Return key would otherwise supply.
    func insert(_ text: String, submit: Bool = false) {
        writeInputDirectly(Data((text + (submit ? "\r" : "")).utf8))
    }

    func connect(using store: HostStore) {
        workingDirectory = nil
        transferConfiguration = nil
        statusStore = store
        let attemptID = UUID()
        connectionAttemptID = attemptID
        if let ssh { Task { await ssh.disconnect() } }
        ssh = nil
        guard let host = store.host(hostID) ?? transientHost else {
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
            host: host, route: route, purpose: .sshSession, username: username
        )
        guard let username, !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            requestAuthentication(
                for: host, username: "", selectedKeyID: identity?.keyID,
                requiresPassphrase: identity?.keyID
                    .flatMap { store.key($0) }?.requiresPassphraseEntry == true
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
                                    publicKey: key.publicKey,
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
                status = .connecting
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
                connectionAttemptID = nil
                requestAuthentication(
                    for: jump, username: identity?.username ?? "",
                    selectedKeyID: identity?.keyID,
                    failureMessage: sshError.localizedDescription,
                    requiresPassphrase:
                        identity?.keyID.flatMap { store.key($0) }?
                        .requiresPassphraseEntry == true
                )
                return
            }
            pendingInitialCommand = nil
            connectionAttemptID = nil
            status = .failed(error.localizedDescription)
            connectionJourney.fail(error.localizedDescription, at: routeHostID(from: error))
            return
        }

        pendingHostKey = nil
        connectionTask?.cancel()
        status = .connecting
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
                    requestAuthentication(
                        for: authenticationHost,
                        username: authenticationIdentity?.username ?? username,
                        selectedKeyID: authenticationIdentity?.keyID ?? selectedKeyID,
                        failureMessage: (credentialFailures
                            + [sshError.localizedDescription]).joined(separator: "\n"),
                        requiresPassphrase:
                            selectedKeyID
                            .flatMap { store.key($0) }?.requiresPassphraseEntry == true,
                        mode: sshError.isServerAuthenticationChallenge
                            ? .serverChallenge : .localIdentity
                    )
                } else {
                    pendingInitialCommand = nil
                    status = .failed(error.localizedDescription)
                    connectionJourney.fail(error.localizedDescription, at: routeHostID(from: error))
                }
            }
        }
    }

    func continueAuthentication(
        identityID: Identity.ID?, username: String, password: String?, passphrase: String?,
        keyID: SSHKeyRef.ID?, save: Bool,
        using store: HostStore
    ) {
        let selectedIdentity = identityID.flatMap { store.identity($0) }
        let trimmedUsername = (selectedIdentity?.username ?? username)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else { return }
        guard let prompt = pendingAuthentication,
            var host = store.host(prompt.host.id) ?? (prompt.host.id == hostID ? transientHost : nil)
        else { return }

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
            passphrase: passphrase, keyID: submittedKeyID
        )
        if host.id == hostID { usernameHint = trimmedUsername }
        pendingAuthentication = nil
        connectionJourney.resume()

        if save {
            if let selectedIdentity {
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

    func cancelAuthentication() {
        pendingAuthentication = nil
        pendingInitialCommand = nil
        status = .disconnected
        connectionJourney.hide()
    }

    func trustAndConnect(_ observation: SSHHostKeyObservation, using store: HostStore) {
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
        _ observation: SSHHostKeyObservation, using store: HostStore
    ) {
        guard let hostID = pendingHostKeyHostID else { return }
        temporaryHostKeys[hostID] = observation.identity
        pendingHostKey = nil
        pendingHostKeyHostID = nil
        connectionJourney.resume()
        connect(using: store)
    }

    func disconnect() {
        workingDirectory = nil
        transferConfiguration = nil
        pendingInitialCommand = nil
        pendingAuthentication = nil
        pendingHostKey = nil
        pendingHostKeyHostID = nil
        suppliedAuthentications.removeAll()
        temporaryHostKeys.removeAll()
        connectionAttemptID = nil
        connectionTask?.cancel()
        connectionTask = nil
        if let ssh { Task { await ssh.disconnect() } }
        ssh = nil
        status = .disconnected
        connectionJourney.hide()
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
                shellIntegrationEnabled:
                    UserDefaults.standard.object(forKey: SettingsKey.shellIntegration) as? Bool
                    ?? true,
                columns: latestViewport.columns, rows: latestViewport.rows,
                progress: progressHandler(attemptID: attemptID)
            )
            try Task.checkCancellation()
            guard connectionAttemptID == attemptID else { throw CancellationError() }
            transferConfiguration = configuration
            suppliedAuthentications.removeAll()
            temporaryHostKeys.removeAll()
            status = .connected
            connectionJourney.succeed()
            if let command = pendingInitialCommand {
                pendingInitialCommand = nil
                insert(command, submit: true)
            }
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
        workingDirectory = nil
        transferConfiguration = nil
        connectionAttemptID = nil
        ssh = nil
        switch result {
        case .success:
            status = .disconnected
            inputRouter?.closeSSHSessionPane(afterExit: self)
        case .failure(let error):
            status = .failed(error.localizedDescription)
        }
    }

    private func requestAuthentication(
        for host: Host, username: String,
        selectedKeyID: SSHKeyRef.ID?, failureMessage: String? = nil,
        requiresPassphrase: Bool = false,
        mode: SSHAuthenticationPrompt.Mode = .localIdentity
    ) {
        suppliedAuthentications[host.id] = nil
        pendingAuthentication = SSHAuthenticationPrompt(
            host: host, username: username,
            selectedKeyID: selectedKeyID,
            failureMessage: failureMessage?.isEmpty == false ? failureMessage : nil,
            requiresPassphrase: requiresPassphrase, mode: mode
        )
        status = .disconnected
        switch mode {
        case .localIdentity:
            connectionJourney.waitForLocalIdentity(at: host.id, failure: failureMessage)
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
        for host: Host, using store: HostStore, attemptID: UUID
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
            status = .failed(error.localizedDescription)
            connectionJourney.fail(error.localizedDescription, at: host.id)
        }
    }

    private func presentHostKeyPrompt(
        _ observation: SSHHostKeyObservation, kind: SSHHostKeyPrompt.Kind, hostID: Host.ID
    ) {
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
        return copy
    }

    /// Routes terminal-produced bytes only when they came from an explicitly
    /// captured user interaction. Mouse/focus reports and protocol replies use
    /// the direct path even while Broadcast Input is enabled.
    func handleTerminalWrite(_ data: Data, isInteractiveInput: Bool) {
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

    func dismissSuggestion() {
        inlineSuggestion = nil
    }
}

nonisolated struct SSHAuthenticationPrompt: Identifiable, Hashable, Sendable {
    nonisolated enum Mode: Hashable, Sendable {
        case localIdentity
        case serverChallenge
    }

    let id = UUID()
    var host: Host
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
    /// A connected-looking sshSession, for driving P0 layout work.
    static func demo(host: Host) -> SSHSessionModel {
        let sshSession = SSHSessionModel(host: host)
        sshSession.status = .connected
        sshSession.workingDirectory = "/var/log"
        sshSession.latencyMilliseconds = 24
        sshSession.shellIntegrationAvailable = true
        sshSession.inlineSuggestion = SuggestedCommand(
            command: "du -sh /var/* | sort -h",
            explanation: "Find which directory under /var is filling the root volume."
        )
        return sshSession
    }

}
