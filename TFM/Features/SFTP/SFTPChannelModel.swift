import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

import struct TermindDomain.Host

protocol SFTPChannelNavigationRouting: AnyObject {
    func sftpChannel(_ sftpChannel: SFTPChannelModel, didChangePath path: String)
}

/// One row of the browser, with its display strings already rendered.
///
/// The formatters are the reason this type exists. A hand-rolled `LazyVStack`
/// rebuilds every realised row on every body pass, and a divider drag runs one
/// of those per mouse-move frame — so `Date.formatted` and `.byteCount` were
/// being re-run dozens of times a frame for text that only changes when the
/// directory does. Rendering them once per listing moves that cost off the
/// drag entirely.
nonisolated struct SFTPRow: Identifiable, Hashable, Sendable {
    let file: RemoteFile
    let sizeText: String
    let modifiedText: String
    let kindText: String
    let permissionText: String

    var id: RemoteFile.ID { file.id }

    init(file: RemoteFile, kindText: String? = nil) {
        self.file = file
        self.sizeText = file.isDirectory ? "" : DataSizeFormat.bytes(file.size)
        self.modifiedText =
            file.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—"
        self.kindText = kindText ?? file.sftpKindDescription
        self.permissionText = file.permissionDescription
    }
}

/// Rows, filtering, and selection change as one value so a refreshed directory
/// never exposes a selection that is absent from the visible snapshot.
///
/// `visibleRows` is stored rather than computed. Filtering and sorting are
/// O(n log n) over `localizedStandardCompare`, and a computed property put that
/// on every read — which meant twice per SwiftUI body pass, which meant twice
/// per frame of a pane-divider drag. It is rebuilt only when the inputs to it
/// change: the listing, hidden-file visibility, the filter, or the sort.
private struct SFTPDirectoryPresentation {
    var files: [RemoteFile] = []
    var selection: Set<RemoteFile.ID> = []
    var query = ""
    var showsHiddenFiles = false
    var sortField: RemoteFileSortField = .name
    var sortDirection: RemoteFileSortDirection = .ascending
    private(set) var visibleRows: [SFTPRow] = []

    /// Re-filters, re-sorts, and drops any selection that fell out of view.
    /// Every mutation of `files`, hidden visibility, `query`, or the sort has
    /// to go through here.
    mutating func refresh() {
        let displayable = showsHiddenFiles ? files : files.filter { !$0.isHidden }
        let matches =
            query.isEmpty
            ? displayable
            : displayable.filter { $0.name.localizedCaseInsensitiveContains(query) }
        // Decorated before sorting so `sftpKindDescription` — a localised
        // string lookup — runs once per file rather than once per comparison.
        var rows = matches.map { SFTPRow(file: $0) }
        rows.sort(by: rowPrecedes)
        visibleRows = rows
        reconcileSelection()
    }

    /// The cheap path: selection changes cannot alter what is on screen, so
    /// they intersect against the rows already built.
    mutating func reconcileSelection() {
        selection.formIntersection(Set(visibleRows.map(\.id)))
    }

    private func rowPrecedes(_ lhs: SFTPRow, _ rhs: SFTPRow) -> Bool {
        RemoteFileSortDescriptor(field: sortField, direction: sortDirection).precedes(
            lhs.file, rhs.file, lhsKind: lhs.kindText, rhsKind: rhs.kindText
        )
    }
}

@Observable
final class SFTPChannelModel: Identifiable {
    let id = UUID()
    let hostID: Host.ID
    let initialPath: String
    var homeResolution: RemoteHomeResolutionState = .pending
    private(set) var path: String {
        didSet {
            guard path != oldValue else { return }
            navigationRouter?.sftpChannel(self, didChangePath: path)
        }
    }
    var pathText: String
    private(set) var backHistory: [String] = []
    private(set) var forwardHistory: [String] = []
    private var directoryPresentation = SFTPDirectoryPresentation()
    var selection: Set<RemoteFile.ID> {
        get { directoryPresentation.selection }
        set {
            var presentation = directoryPresentation
            presentation.selection = newValue
            presentation.reconcileSelection()
            directoryPresentation = presentation
        }
    }
    var query: String {
        get { directoryPresentation.query }
        set {
            guard newValue != directoryPresentation.query else { return }
            var presentation = directoryPresentation
            presentation.query = newValue
            presentation.refresh()
            directoryPresentation = presentation
        }
    }
    var showsHiddenFiles: Bool {
        get { directoryPresentation.showsHiddenFiles }
        set {
            guard newValue != directoryPresentation.showsHiddenFiles else { return }
            var presentation = directoryPresentation
            presentation.showsHiddenFiles = newValue
            presentation.refresh()
            directoryPresentation = presentation
        }
    }
    var sortField: RemoteFileSortField { directoryPresentation.sortField }
    var sortDirection: RemoteFileSortDirection { directoryPresentation.sortDirection }
    var files: [RemoteFile] { directoryPresentation.files }
    private(set) var status: ConnectionStatus = .disconnected {
        didSet {
            statusStore?.setConnectionStatus(status, connectionID: id, hostID: hostID)
        }
    }
    private(set) var isLoading = false
    private(set) var hint = ""
    var pendingHostKey: SSHHostKeyPrompt? { connection.pendingHostKey }
    var pendingAuthentication: SSHAuthenticationPrompt?
    let connection = RemoteSessionConnectionController()
    var connectionJourney: ConnectionJourney { connection.journey }
    private var pendingDownloadBatch: SFTPRemoteDownloadBatch?
    var pendingUploadBatch: SFTPLocalUploadBatch?
    var pendingRemoteCopyBatch: SFTPRemoteCopyBatch?
    var operationError: String?
    private(set) var canCancelOperation = false

    private var client: (any SFTPChannelProtocol)?
    private var transferContext: SFTPTransferContext?
    private var configuration: SSHConnectionConfiguration?
    private var usesEphemeralCredentials = false
    private var connectionTask: Task<Void, Never>?
    private var startsOnMount = true
    private var automaticRefreshTask: Task<Void, Never>?
    private var uploadRefreshTask: Task<Void, Never>?
    private var suppliedAuthentications: [Host.ID: SSHAuthenticationSubmission] = [:]
    private var temporaryHostKeys: [Host.ID: SSHHostKeyIdentity] {
        get { connection.temporaryHostKeys }
        set { connection.temporaryHostKeys = newValue }
    }
    private var connectionAttemptID: UUID?
    private var reconnectController: SessionReconnectController { connection.reconnect }
    private var operationCancellation: TransferCancellationToken?
    weak var navigationRouter: (any SFTPChannelNavigationRouting)?
    private weak var statusStore: (any RemoteSessionHostStore)?
    private weak var transferCoordinator: SFTPTransferCoordinator?
    weak var historyStore: SFTPHistoryModel?
    private var didResolveHomeForConnection = false
    private let automaticRefreshInterval: Duration
    var connectionCoordinator: RemoteConnectionCoordinator?

    init(
        hostID: Host.ID,
        initialPath: String = "",
        client: (any SFTPChannelProtocol)? = nil,
        configuration: SSHConnectionConfiguration? = nil,
        primaryRole: SFTPTransferPrimaryRole = .control,
        homeResolution: RemoteHomeResolutionState = .pending,
        automaticRefreshInterval: Duration = .seconds(15)
    ) {
        self.hostID = hostID
        let configuredPath = initialPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = configuredPath.isEmpty ? "/" : RemotePath.normalized(configuredPath)
        self.initialPath = configuredPath.isEmpty ? "" : path
        self.path = path
        self.pathText = path
        self.client = client
        startsOnMount = client == nil
        self.configuration = configuration
        if let client, let configuration {
            transferContext = SFTPTransferContext(
                configuration: configuration, channel: client, primaryRole: primaryRole)
        }
        self.homeResolution = homeResolution
        self.automaticRefreshInterval = automaticRefreshInterval
        if client != nil { status = .connected }
        if client != nil { _ = connection.markConnected() }
    }

    var reconnectState: ReconnectState? { connection.reconnectState }
    var allowsRemoteMutations: Bool { status == .connected }
    var displayedPath: String? {
        guard !homeResolution.isPending else { return nil }
        return displayPath(path)
    }

    func displayPath(_ path: String) -> String {
        RemotePath.displayed(path, home: homeResolution)
    }

    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    var conflictCount: Int {
        pendingRemoteCopyBatch?.conflictCount
            ?? pendingUploadBatch?.conflictCount
            ?? pendingDownloadBatch?.conflictCount
            ?? 0
    }
    var hasPendingBatch: Bool {
        pendingUploadBatch != nil || pendingDownloadBatch != nil || pendingRemoteCopyBatch != nil
    }
    /// What the list draws. Already filtered, sorted, and formatted.
    var visibleRows: [SFTPRow] { directoryPresentation.visibleRows }
    /// The same rows as plain files, for selection and menu work. Only ever
    /// reached from event handlers, never from a body pass.
    var filteredFiles: [RemoteFile] { directoryPresentation.visibleRows.map(\.file) }
    var selectedFiles: [RemoteFile] {
        directoryPresentation.visibleRows.filter { selection.contains($0.id) }.map(\.file)
    }

    /// Returns whether a new single selection was made. The view owns the
    /// corresponding keyboard anchor and focus changes.
    func selectForContextMenu(_ file: RemoteFile) -> Bool {
        guard !selection.contains(file.id) else { return false }
        selection = [file.id]
        return true
    }

    func menuTargets(for file: RemoteFile) -> [RemoteFile] {
        guard selection.contains(file.id), selection.count > 1 else { return [file] }
        return selectedFiles
    }

    func sort(by field: RemoteFileSortField) {
        var presentation = directoryPresentation
        if presentation.sortField == field {
            presentation.sortDirection.toggle()
        } else {
            presentation.sortField = field
            presentation.sortDirection = field.defaultDirection
        }
        presentation.refresh()
        directoryPresentation = presentation
    }

    func remoteCopySource(for files: [RemoteFile]) -> SFTPRemoteCopySource? {
        guard status == .connected, let connection = transferConnection, !files.isEmpty else {
            return nil
        }
        return SFTPRemoteCopySource(
            hostID: hostID, connection: connection, files: files,
            homeDirectory: homeResolution.resolvedDirectory
        )
    }

    private var transferConnection: SFTPTransferConnection? {
        transferContext.map(SFTPTransferConnection.context)
    }

    func prepareForReopen() {
        startsOnMount = true
    }

    func connectIfNeeded(using store: any RemoteSessionHostStore) {
        guard startsOnMount, status == .disconnected else { return }
        connect(using: store)
    }

    func connect(using store: any RemoteSessionHostStore) {
        startsOnMount = false
        startConnection(using: store)
    }

    private func startConnection(using store: any RemoteSessionHostStore) {
        let reconnecting = connection.hasConnectedOnce && connection.isRecovering
        homeResolution = .pending
        didResolveHomeForConnection = false
        bindStatus(to: store)
        connectionTask?.cancel()
        connection.clearHostKeyPrompt()
        guard let host = store.host(hostID) else {
            connection.stopRecovery()
            let message = String(localized: "The host is no longer available.")
            status = .failed(message)
            homeResolution = .unavailable
            connectionJourney.fail(message)
            return
        }
        let attemptID = UUID()
        connectionAttemptID = attemptID
        let route = store.route(for: host)
        let suppliedAuthentication = suppliedAuthentications[host.id]
        connectionJourney.begin(
            host: host, route: route, purpose: .sftpChannel,
            username: suppliedAuthentication?.username ?? store.identity(for: host)?.username,
            mode: reconnecting ? .reconnection : .connection
        )
        if let passphraseHost = route.first(where: { routeHost in
            guard let submission = suppliedAuthentications[routeHost.id],
                submission.passphrase == nil,
                let keyID = submission.keyID,
                let key = store.key(keyID)
            else { return false }
            return key.requiresPassphraseEntry
        }) {
            requestAuthentication(
                host: passphraseHost, store: store,
                requiresPassphrase: true, preserveSubmission: true
            )
            return
        }
        if reconnecting, usesEphemeralCredentials, suppliedAuthentication == nil {
            requestAuthentication(host: host, store: store)
            return
        }
        status = reconnecting ? .reconnecting : .connecting
        hint =
            reconnecting
            ? String(localized: "Reconnecting") : String(localized: "Connecting")
        connectionTask = Task { [weak self, weak store] in
            guard let self, let store else { return }
            do {
                let configuration: SSHConnectionConfiguration
                if let suppliedAuthentication {
                    let expectedHostKeys = try store.expectedHostKeys(
                        for: host, temporaryHostKeys: temporaryHostKeys,
                        trustPolicy: .allowChallenge
                    )
                    var credentials: [SSHCredentials] = []
                    if let keyID = suppliedAuthentication.keyID,
                        let key = store.key(keyID),
                        let stored = try? store.connectionKeyCredential(
                            for: key, identityID: suppliedAuthentication.identityID
                        )
                    {
                        credentials.append(
                            stored.sshCredential(
                                publicKey: key.publicKey, certificate: key.certificate,
                                passphraseOverride: suppliedAuthentication.passphrase
                            ))
                    }
                    if let password = suppliedAuthentication.password {
                        credentials.append(.password(password))
                    }
                    configuration = SSHConnectionConfiguration(
                        hostID: host.id, host: host.host, port: host.port,
                        username: suppliedAuthentication.username,
                        credentials: credentials,
                        expectedHostKeys: expectedHostKeys,
                        proxy: try store.transportProxy(for: host),
                        jumps: try store.sshJumpConfigurations(
                            for: host, submissions: suppliedAuthentications,
                            temporaryHostKeys: temporaryHostKeys,
                            trustPolicy: .allowChallenge
                        )
                    )
                } else {
                    configuration = try store.sshConnectionConfiguration(
                        for: host, submissions: suppliedAuthentications,
                        temporaryHostKeys: temporaryHostKeys,
                        trustPolicy: .allowChallenge
                    )
                }
                let coordinator = self.connectionCoordinator ?? RemoteConnectionCoordinator()
                let client = try await coordinator.connectSFTP(
                    using: SSHConnectionRequest(
                        configuration: configuration,
                        authorizeHostKey: { [weak self, weak store] challenge in
                            guard let self, let store else { throw CancellationError() }
                            return await self.connection.authorizeHostKey(
                                challenge, using: store
                            )
                        },
                        keyboardInteractive: { [weak self] challenge in
                            guard let self, await self.connectionAttemptID == attemptID else {
                                throw CancellationError()
                            }
                            return try await self.connection.answerKeyboardInteractive(challenge)
                        }
                    ),
                    progress: progressHandler(attemptID: attemptID),
                    connectionFailure: { [weak self] message in
                        Task { @MainActor in
                            self?.handleConnectionFailure(message, attemptID: attemptID)
                        }
                    }
                )
                guard !Task.isCancelled, self.connectionAttemptID == attemptID else {
                    await client.disconnect()
                    return
                }
                do {
                    try await self.resolveInitialPathIfNeeded(using: client)
                } catch {
                    await client.disconnect()
                    throw error
                }
                guard !Task.isCancelled, self.connectionAttemptID == attemptID else {
                    await client.disconnect()
                    return
                }
                self.connectionJourney.receive(.connected(host.id))
                self.client = client
                let transferConfiguration = store.configurationForAdditionalConnection(from: configuration)
                self.transferContext = SFTPTransferContext(configuration: transferConfiguration, channel: client)
                self.configuration = transferConfiguration
                self.suppliedAuthentications.removeAll()
                self.temporaryHostKeys.removeAll()
                self.pendingAuthentication = nil
                let presentsConnectionJourney = self.connectionJourney.isPresented
                _ = self.connection.markConnected()
                self.status = .connected
                if presentsConnectionJourney {
                    self.connectionJourney.succeed()
                } else {
                    self.connectionJourney.hide()
                }
                self.hint = ""
                await self.reload()
                self.startAutomaticRefresh()
            } catch is CancellationError {
                guard self.connectionAttemptID == attemptID else { return }
                self.status = .disconnected
                self.homeResolution = .unavailable
            } catch TermindSSHError.missingCredential,
                TermindSSHError.missingUsername,
                TermindSSHError.keyPassphraseRequired
            {
                guard self.connectionAttemptID == attemptID else { return }
                self.requestAuthentication(host: host, store: store)
            } catch let error as TermindSSHError where error.shouldRequestAuthentication {
                guard self.connectionAttemptID == attemptID else { return }
                let authenticationHost: Host
                if let id = error.routeHostID, let jump = store.host(id) {
                    authenticationHost = jump
                } else {
                    authenticationHost = host
                }
                let submitted = self.suppliedAuthentications[authenticationHost.id]
                let retryNeedsPassphrase =
                    submitted?.passphrase == nil
                    && (submitted?.keyID ?? store.identity(for: authenticationHost)?.keyID)
                        .flatMap { store.key($0) }?.requiresPassphraseEntry == true
                let returnsToIdentity = submitted?.passphrase != nil
                self.requestAuthentication(
                    host: authenticationHost, store: store,
                    failure: error.localizedDescription,
                    mode: !returnsToIdentity && error.isServerAuthenticationChallenge
                        ? .serverChallenge : .localIdentity,
                    requiresPassphrase: retryNeedsPassphrase,
                    preserveSubmission: retryNeedsPassphrase && submitted != nil
                )
            } catch {
                guard self.connectionAttemptID == attemptID else { return }
                if self.connection.hasConnectedOnce || reconnecting {
                    self.scheduleReconnect(after: error.localizedDescription, using: store)
                } else {
                    self.status = .failed(error.localizedDescription)
                    self.homeResolution = .unavailable
                    self.hint = error.localizedDescription
                    self.connectionJourney.fail(
                        error.localizedDescription,
                        at: (error as? TermindSSHError)?.routeHostID
                    )
                }
            }
        }
    }

    func bindStatus(to store: any RemoteSessionHostStore) {
        statusStore = store
        store.setConnectionStatus(status, connectionID: id, hostID: hostID)
    }

    func bindTransfers(to coordinator: SFTPTransferCoordinator) {
        transferCoordinator = coordinator
    }

    func disconnect() {
        startsOnMount = false
        cancelPendingBatch()
        pendingAuthentication = nil
        suppliedAuthentications.removeAll()
        connectionTask?.cancel()
        connectionTask = nil
        connectionAttemptID = nil
        connection.disconnect()
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        uploadRefreshTask?.cancel()
        uploadRefreshTask = nil
        let client = client
        let transferContext = transferContext
        self.transferContext = nil
        self.client = nil
        configuration = nil
        usesEphemeralCredentials = false
        status = .disconnected
        homeResolution = .unavailable
        replaceDirectoryContents(with: [])
        Task {
            if let transferContext { await transferContext.releaseOwner() } else { await client?.disconnect() }
        }
    }

    func retryReconnectNow() {
        reconnectController.retryNow()
    }

    func stopReconnecting() {
        guard let reconnectState else { return }
        connection.stopRecovery()
        connectionAttemptID = nil
        connectionTask?.cancel()
        connectionTask = nil
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        let client = client
        let transferContext = transferContext
        self.transferContext = nil
        self.client = nil
        configuration = nil
        status = .failed(reconnectState.lastError)
        homeResolution = .unavailable
        hint = reconnectState.lastError
        connectionJourney.fail(reconnectState.lastError)
        Task {
            if let transferContext { await transferContext.retire() } else { await client?.disconnect() }
        }
    }

    func resolveInitialPathIfNeeded(using client: any SFTPChannelProtocol) async throws {
        guard !didResolveHomeForConnection else { return }
        didResolveHomeForConnection = true
        do {
            let proposed = try await client.homeDirectory()
            guard proposed.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") else {
                throw SFTPError.operation("The remote home directory is not absolute.")
            }
            let home = RemotePath.normalized(proposed)
            homeResolution = .resolved(home)
            if initialPath.isEmpty {
                path = home
                pathText = home
            }
        } catch {
            homeResolution = .unavailable
            guard !initialPath.isEmpty else { throw error }
        }
        navigationRouter?.sftpChannel(self, didChangePath: path)
    }

    func trustAndConnect(_ observation: SSHHostKeyObservation, using store: any RemoteSessionHostStore) {
        connection.trustHostKey(observation, using: store)
    }

    func continueWithTemporaryHostKey(_ observation: SSHHostKeyObservation) {
        _ = connection.useTemporaryHostKey(observation)
    }

    func continueAuthentication(
        identityID: Identity.ID?, username: String, password: String?, passphrase: String?,
        keyID: SSHKeyRef.ID?, save: Bool, using store: any RemoteSessionHostStore
    ) {
        guard let prompt = pendingAuthentication,
            let host = store.host(prompt.host.id)
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

        let selectedIdentity = identityID.flatMap { store.identity($0) }
        let submittedUsername = (selectedIdentity?.username ?? username)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedUsername.isEmpty else { return }
        let submittedKeyID = selectedIdentity?.keyID ?? keyID
        let submission: SSHAuthenticationSubmission
        do {
            submission = try store.authenticationSubmission(
                username: submittedUsername, password: password, passphrase: passphrase,
                keyID: submittedKeyID, selectedIdentity: selectedIdentity
            )
        } catch {
            requestAuthentication(host: host, store: store, failure: error.localizedDescription)
            return
        }

        suppliedAuthentications[host.id] = submission
        usesEphemeralCredentials =
            !save
            && (password != nil || passphrase != nil
                || (selectedIdentity == nil && submittedKeyID == nil))
        pendingAuthentication = nil
        connectionJourney.resume()
        if save {
            do {
                _ = try store.saveAuthentication(
                    submission, for: host, selectedIdentity: selectedIdentity, suppliedPassword: password
                )
            } catch {
                operationError = error.localizedDescription
                requestAuthentication(host: host, store: store, failure: error.localizedDescription)
                return
            }
        }
        connect(using: store)
    }

    func navigate(to destination: String) {
        let destination = RemotePath.normalized(destination)
        guard destination != path else {
            reloadNow()
            return
        }
        backHistory.append(path)
        path = destination
        pathText = destination
        forwardHistory.removeAll()
        selection.removeAll()
        reloadNow()
    }

    func goBack() {
        guard let destination = backHistory.popLast() else { return }
        forwardHistory.append(path)
        path = destination
        pathText = destination
        selection.removeAll()
        reloadNow()
    }

    func goForward() {
        guard let destination = forwardHistory.popLast() else { return }
        backHistory.append(path)
        path = destination
        pathText = destination
        selection.removeAll()
        reloadNow()
    }

    func commitPathText() { navigate(to: pathText) }
    func reloadNow() { Task { await reload() } }

    func reload(silently: Bool = false) async {
        guard let client, status == .connected else { return }
        let requestedPath = path
        if !silently {
            isLoading = true
            hint = String(localized: "Loading")
        }
        defer { if !silently { isLoading = false } }
        do {
            let snapshot = try await client.listDirectory(at: requestedPath)
            guard status == .connected, path == requestedPath else { return }
            replaceDirectoryContents(with: snapshot)
            if !silently {
                historyStore?.record(kind: .directory, path: requestedPath, for: hostID)
            }
            hint = String(localized: "\(snapshot.count) items")
        } catch let error as SFTPError {
            if case .connectionLost(let message) = error {
                handleConnectionFailure(message, attemptID: connectionAttemptID)
                return
            }
            if case .notConnected = error {
                handleConnectionFailure(
                    error.localizedDescription, attemptID: connectionAttemptID
                )
                return
            }
            guard !silently else { return }
            operationError = error.localizedDescription
            hint = error.localizedDescription
        } catch {
            guard !silently else { return }
            operationError = error.localizedDescription
            hint = error.localizedDescription
        }
    }

    func startAutomaticRefresh() {
        guard status == .connected, automaticRefreshTask == nil else { return }
        let interval = automaticRefreshInterval
        automaticRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                await self.reload(silently: true)
            }
        }
    }

    /// Publishes rows and their valid selection in one observable mutation so
    /// SwiftUI never receives an intermediate table state.
    private func replaceDirectoryContents(with files: [RemoteFile]) {
        var presentation = directoryPresentation
        presentation.files = files
        presentation.refresh()
        directoryPresentation = presentation
    }

    func scheduleSilentRefresh(after delay: Duration = .milliseconds(250)) {
        uploadRefreshTask?.cancel()
        uploadRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.reload(silently: true)
        }
    }

    func createFolder(named name: String) async {
        guard let client else { return }
        do {
            try await client.createDirectory(named: name, in: path)
            await reload()
        } catch { operationError = error.localizedDescription }
    }

    func rename(_ file: RemoteFile, to name: String) async {
        guard let client else { return }
        do {
            try await client.rename(file, to: name)
            await reload()
        } catch { operationError = error.localizedDescription }
    }

    @discardableResult
    func updatePermissions(for file: RemoteFile, to permissions: UInt32) async -> Bool {
        guard status == .connected, let client else {
            operationError = String(localized: "The SFTP connection is not available.")
            return false
        }
        do {
            try await client.setPermissions(of: file, to: permissions)
            await reload()
            return true
        } catch {
            operationError = error.localizedDescription
            return false
        }
    }

    func delete(_ files: [RemoteFile]) async {
        guard let client else { return }
        let cancellation = TransferCancellationToken()
        operationCancellation = cancellation
        canCancelOperation = true
        isLoading = true
        do {
            for file in files {
                try await deleteRecursively(file, client: client, cancellation: cancellation)
            }
            selection.subtract(files.map(\.id))
            await reload()
        } catch SFTPError.cancelled {
            hint = String(localized: "Deletion cancelled")
            isLoading = false
        } catch {
            operationError = error.localizedDescription
            isLoading = false
        }
        operationCancellation = nil
        canCancelOperation = false
    }

    func cancelOperation() { operationCancellation?.cancel() }

    func cancelPendingBatch() {
        pendingUploadBatch = nil
        pendingDownloadBatch = nil
        pendingRemoteCopyBatch = nil
    }

    func prepareUpload(_ urls: [URL]) async {
        guard let client else { return }
        do {
            let batch = try await SFTPLocalUploadPlanner.prepare(
                urls,
                destination: path,
                client: client
            )
            pendingDownloadBatch = nil
            pendingRemoteCopyBatch = nil
            pendingUploadBatch = batch.isEmpty ? nil : batch
        } catch {
            pendingUploadBatch = nil
            operationError = error.localizedDescription
        }
    }

    func prepareDownload(_ files: [RemoteFile], to directory: URL) async {
        guard let client else { return }
        do {
            pendingUploadBatch = nil
            let batch = try await SFTPRemoteDownloadPlanner.prepare(
                files, destination: directory, client: client
            )
            pendingRemoteCopyBatch = nil
            pendingDownloadBatch = batch
        } catch { operationError = error.localizedDescription }
    }

    func prepareRemoteCopy(
        _ payload: SFTPRemoteItemsPayload,
        coordinator: SFTPTransferCoordinator
    ) async {
        bindTransfers(to: coordinator)
        guard let client else { return }
        do {
            pendingUploadBatch = nil
            let batch = try await SFTPRemoteCopyPlanner.prepare(
                payload, destination: path, client: client, coordinator: coordinator
            )
            pendingDownloadBatch = nil
            pendingRemoteCopyBatch = batch
        } catch {
            operationError = error.localizedDescription
        }
    }

    func open(
        _ file: RemoteFile, coordinator: SFTPTransferCoordinator,
        edits: SFTPEditService? = nil, completion: @escaping (URL) -> Void
    ) {
        bindTransfers(to: coordinator)
        guard !file.isDirectory, let connection = transferConnection else { return }
        if let edits, let client {
            Task {
                do {
                    let url = try await edits.open(
                        file, hostID: hostID, connection: connection, client: client,
                        homeDirectory: homeResolution.resolvedDirectory, configuration: configuration)
                    completion(url)
                } catch { operationError = error.localizedDescription }
            }
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Termind", isDirectory: true)
            .appendingPathComponent("Open", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let localURL = directory.appendingPathComponent(file.name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            coordinator.enqueue(
                direction: .download, batchID: UUID(), localURL: localURL,
                remotePath: file.path, byteCount: file.size, hostID: hostID,
                connection: connection, scopedRoot: directory, overwrite: false,
                homeDirectory: homeResolution.resolvedDirectory
            ) { state in
                if state == .completed {
                    completion(localURL)
                }
            }
        } catch { operationError = error.localizedDescription }
    }

    func uploadEdit(_ id: UUID, using edits: SFTPEditService, replacing: Bool) async -> Bool {
        guard status == .connected, let connection = transferConnection, let client else { return false }
        return await edits.upload(
            id, connection: connection, client: client,
            homeDirectory: homeResolution.resolvedDirectory, replacing: replacing, configuration: configuration
        ) { [weak self] in self?.scheduleSilentRefresh() }
    }

    func recordOpenedFile(at path: String) {
        historyStore?.record(kind: .file, path: path, for: hostID)
    }

    func reopenHistoryFile(
        at path: String, coordinator: SFTPTransferCoordinator,
        edits: SFTPEditService? = nil, completion: @escaping (URL) -> Void
    ) {
        guard let client, status == .connected else {
            operationError = String(localized: "The SFTP connection is not available.")
            return
        }
        Task {
            do {
                guard let file = try await client.attributes(at: path), !file.isDirectory else {
                    operationError = String(localized: "The remote file is no longer available.")
                    return
                }
                open(file, coordinator: coordinator, edits: edits, completion: completion)
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    func downloadPromisedFile(
        _ file: RemoteFile, to destinationDirectory: URL,
        coordinator: SFTPTransferCoordinator,
        completion: @escaping ((any Error)?) -> Void
    ) {
        bindTransfers(to: coordinator)
        guard !file.isDirectory, let connection = transferConnection else {
            completion(SFTPError.notConnected)
            return
        }
        let localURL = destinationDirectory.appendingPathComponent(file.name)
        coordinator.enqueue(
            direction: .download, batchID: UUID(), localURL: localURL,
            remotePath: file.path, byteCount: file.size, hostID: hostID,
            connection: connection, scopedRoot: destinationDirectory,
            overwrite: false, homeDirectory: homeResolution.resolvedDirectory
        ) { state in
            switch state {
            case .completed:
                completion(nil)
            case .cancelled:
                completion(SFTPError.cancelled)
            case .failed(let message):
                completion(SFTPError.operation(message))
            case .queued, .running, .paused:
                completion(SFTPError.operation("The promised download did not finish."))
            }
        }
    }

    func enqueuePending(policy: TransferConflictPolicy, coordinator: SFTPTransferCoordinator) async {
        bindTransfers(to: coordinator)
        if let batch = pendingUploadBatch {
            guard let connection = transferConnection, let client else { return }
            pendingUploadBatch = nil
            do {
                let result = try await SFTPLocalUploadPlanner.enqueue(
                    batch,
                    policy: policy,
                    hostID: hostID,
                    connection: connection,
                    homeDirectory: homeResolution.resolvedDirectory,
                    client: client,
                    coordinator: coordinator
                ) { [weak self] state in
                    if state == .completed { self?.scheduleSilentRefresh() }
                }
                if result.changedRemoteDirectories { scheduleSilentRefresh() }
            } catch {
                operationError = error.localizedDescription
            }
            return
        }
        guard let batch = pendingDownloadBatch, let connection = transferConnection, client != nil else {
            return
        }
        pendingDownloadBatch = nil
        do {
            try SFTPRemoteDownloadPlanner.enqueue(
                batch, policy: policy, hostID: hostID, connection: connection,
                homeDirectory: homeResolution.resolvedDirectory, coordinator: coordinator
            )
        } catch { operationError = error.localizedDescription }
    }

    func enqueuePendingRemoteCopy(
        policy: TransferConflictPolicy,
        coordinator: SFTPTransferCoordinator
    ) async {
        bindTransfers(to: coordinator)
        guard let batch = pendingRemoteCopyBatch,
            let destinationConnection = transferConnection,
            let client
        else { return }
        pendingRemoteCopyBatch = nil
        do {
            let changedDirectories = try await SFTPRemoteCopyPlanner.enqueue(
                batch, policy: policy, destinationHostID: hostID,
                destinationConnection: destinationConnection,
                destinationHomeDirectory: homeResolution.resolvedDirectory,
                client: client, coordinator: coordinator
            ) { [weak self] state in
                if state == .completed { self?.scheduleSilentRefresh() }
            }
            if changedDirectories { scheduleSilentRefresh() }
        } catch {
            operationError = error.localizedDescription
        }
    }

    func copyForBrowsing() -> SFTPChannelModel {
        let copy = SFTPChannelModel(hostID: hostID, initialPath: initialPath)
        copy.connectionCoordinator = connectionCoordinator
        return copy
    }

    private func requestAuthentication(
        host: Host, store: any RemoteSessionHostStore, failure: String? = nil,
        mode: SSHAuthenticationPrompt.Mode = .localIdentity,
        requiresPassphrase: Bool? = nil,
        preserveSubmission: Bool = false
    ) {
        connection.pauseForUserInteraction()
        if !preserveSubmission { suppliedAuthentications[host.id] = nil }
        let identity = store.identity(for: host)
        let submission = suppliedAuthentications[host.id]
        let selectedKeyID = submission?.keyID ?? identity?.keyID
        let username = submission?.username ?? identity?.username ?? ""
        let needsPassphrase =
            requiresPassphrase
            ?? (!username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && selectedKeyID.flatMap { store.key($0) }?.requiresPassphraseEntry == true)
        pendingAuthentication = SSHAuthenticationPrompt(
            host: host, selectedIdentityID: submission?.identityID ?? identity?.id,
            username: username,
            selectedKeyID: selectedKeyID,
            failureMessage: failure,
            requiresPassphrase: needsPassphrase,
            mode: mode
        )
        status = .disconnected
        switch mode {
        case .localIdentity:
            if pendingAuthentication?.requiresPassphrase == true {
                connectionJourney.waitForLocalPassphrase(at: host.id, failure: failure)
            } else {
                connectionJourney.waitForLocalIdentity(at: host.id, failure: failure)
            }
        case .serverChallenge:
            connectionJourney.waitForAuthentication(at: host.id, failure: failure)
        }
    }

    private func progressHandler(attemptID: UUID) -> SSHRouteProgressHandler {
        connection.progressHandler(attemptID: attemptID) { [weak self] id in
            self?.connectionAttemptID == id
        }
    }

    private func handleConnectionFailure(_ message: String, attemptID: UUID?) {
        guard connection.hasConnectedOnce, connectionAttemptID == attemptID,
            let store = statusStore
        else { return }
        scheduleReconnect(after: message, using: store)
    }

    private func scheduleReconnect(after message: String, using store: any RemoteSessionHostStore) {
        connectionAttemptID = nil
        connectionTask?.cancel()
        connectionTask = nil
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        uploadRefreshTask?.cancel()
        uploadRefreshTask = nil
        let client = client
        let transferContext = transferContext
        self.transferContext = nil
        self.client = nil
        configuration = nil
        status = .reconnecting
        hint = String(localized: "Reconnecting")
        let host = store.host(hostID)
        connection.presentReconnectJourney(
            host: host, using: store, purpose: .sftpChannel,
            username: host.flatMap { store.identity(for: $0)?.username }
        )
        connection.scheduleRecovery(after: message) { [weak self, weak store] in
            guard let self, let store else { return }
            self.startConnection(using: store)
        }
        Task {
            if let transferContext { await transferContext.retire() } else { await client?.disconnect() }
        }
    }

    private func deleteRecursively(
        _ file: RemoteFile, client: any SFTPChannelProtocol,
        cancellation: TransferCancellationToken? = nil
    ) async throws {
        if cancellation?.isCancelled == true { throw SFTPError.cancelled }
        hint = displayPath(file.path)
        if file.isDirectory {
            for child in try await client.listDirectory(at: file.path) {
                try await deleteRecursively(child, client: client, cancellation: cancellation)
            }
            if cancellation?.isCancelled == true { throw SFTPError.cancelled }
            try await client.removeDirectory(at: file.path)
        } else {
            try await client.removeFile(at: file.path)
        }
    }

}

// MARK: - Demo data

extension SFTPChannelModel {
    /// A populated browser backed only by value data. It deliberately has no
    /// client, so screenshot and preview work can never mutate a remote host.
    static func demo(hostID: Host.ID, path: String = "/etc/nginx") -> SFTPChannelModel {
        let session = SFTPChannelModel(hostID: hostID, initialPath: path)
        session.status = .connected
        let now = Date(timeIntervalSinceReferenceDate: 809_020_800)
        session.replaceDirectoryContents(with: [
            RemoteFile(
                path: "\(path)/conf.d", name: "conf.d", kind: .directory, size: 0,
                modifiedAt: now.addingTimeInterval(-3_600), permissions: 0o755,
                ownerUID: 0, ownerGID: 0
            ),
            RemoteFile(
                path: "\(path)/nginx.conf", name: "nginx.conf", kind: .file, size: 1_842,
                modifiedAt: now.addingTimeInterval(-7_200), permissions: 0o644,
                ownerUID: 0, ownerGID: 0
            ),
            RemoteFile(
                path: "\(path)/mime.types", name: "mime.types", kind: .file, size: 5_346,
                modifiedAt: now.addingTimeInterval(-86_400), permissions: 0o644,
                ownerUID: 0, ownerGID: 0
            ),
            RemoteFile(
                path: "\(path)/proxy_params", name: "proxy_params", kind: .file, size: 636,
                modifiedAt: now.addingTimeInterval(-172_800), permissions: 0o644,
                ownerUID: 0, ownerGID: 0
            ),
        ])
        return session
    }
}
