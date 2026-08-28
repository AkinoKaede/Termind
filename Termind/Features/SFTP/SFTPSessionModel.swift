import Foundation

protocol SFTPSessionNavigationRouting: AnyObject {
    func sftpSession(_ sftpSession: SFTPSessionModel, didChangePath path: String)
}

nonisolated enum SFTPFileSortField: String, CaseIterable, Sendable {
    case name
    case modified
    case size
    case kind

    var defaultDirection: SFTPFileSortDirection {
        switch self {
        case .modified, .size: .descending
        case .name, .kind: .ascending
        }
    }
}

nonisolated enum SFTPFileSortDirection: String, Sendable {
    case ascending
    case descending

    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
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
        self.sizeText = file.isDirectory ? "--" : file.size.formatted(.byteCount(style: .file))
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
    var sortField: SFTPFileSortField = .name
    var sortDirection: SFTPFileSortDirection = .ascending
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
        if lhs.file.isDirectory != rhs.file.isDirectory { return lhs.file.isDirectory }

        let primary = compare(lhs, rhs)
        if primary != .orderedSame {
            return sortDirection == .ascending
                ? primary == .orderedAscending
                : primary == .orderedDescending
        }

        let name = lhs.file.name.localizedStandardCompare(rhs.file.name)
        if name != .orderedSame { return name == .orderedAscending }
        return lhs.file.path.localizedStandardCompare(rhs.file.path) == .orderedAscending
    }

    private func compare(_ lhs: SFTPRow, _ rhs: SFTPRow) -> ComparisonResult {
        switch sortField {
        case .name:
            return lhs.file.name.localizedStandardCompare(rhs.file.name)
        case .modified:
            switch (lhs.file.modifiedAt, rhs.file.modifiedAt) {
            case (.none, .none): return .orderedSame
            case (.none, .some):
                return sortDirection == .ascending ? .orderedDescending : .orderedAscending
            case (.some, .none):
                return sortDirection == .ascending ? .orderedAscending : .orderedDescending
            case (.some(let left), .some(let right)):
                return left == right
                    ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            }
        case .size:
            return lhs.file.size == rhs.file.size
                ? .orderedSame
                : (lhs.file.size < rhs.file.size ? .orderedAscending : .orderedDescending)
        case .kind:
            return lhs.kindText.localizedStandardCompare(rhs.kindText)
        }
    }
}

@Observable
final class SFTPSessionModel: Identifiable {
    struct PreparedJob {
        var direction: SFTPTransfer.Direction
        var localURL: URL
        var remotePath: String
        var byteCount: Int64
        var scopedRoot: URL
        var hasConflict: Bool
        var conflictingTargetIsDirectory: Bool
    }

    struct PreparedBatch {
        var id = UUID()
        var jobs: [PreparedJob]
        var remoteDirectories: [String]
        var remoteDirectoryConflicts: Set<String>
        var localDirectories: [URL]
        var localDirectoryConflicts: Set<URL>
        var conflictCount: Int
    }

    struct PreparedRemoteCopyJob {
        var sourcePath: String
        var destinationPath: String
        var byteCount: Int64
        var hasConflict: Bool
        var conflictingTargetIsDirectory: Bool
    }

    struct PreparedRemoteCopyBatch {
        var id = UUID()
        var source: SFTPRemoteCopySource
        var jobs: [PreparedRemoteCopyJob]
        var remoteDirectories: [String]
        var remoteDirectoryConflicts: Set<String>
        var conflictCount: Int
    }

    let id = UUID()
    let hostID: Host.ID
    let initialPath: String
    private(set) var path: String {
        didSet {
            guard path != oldValue else { return }
            navigationRouter?.sftpSession(self, didChangePath: path)
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
    var sortField: SFTPFileSortField { directoryPresentation.sortField }
    var sortDirection: SFTPFileSortDirection { directoryPresentation.sortDirection }
    var files: [RemoteFile] { directoryPresentation.files }
    private(set) var status: ConnectionStatus = .disconnected {
        didSet {
            statusStore?.setConnectionStatus(status, connectionID: id, hostID: hostID)
        }
    }
    private(set) var isLoading = false
    private(set) var hint = ""
    var pendingHostKey: SSHHostKeyPrompt?
    private var pendingHostKeyHostID: Host.ID?
    var pendingAuthentication: SSHAuthenticationPrompt?
    let connectionJourney = SSHConnectionJourney()
    var pendingBatch: PreparedBatch?
    var pendingRemoteCopyBatch: PreparedRemoteCopyBatch?
    var operationError: String?
    private(set) var canCancelOperation = false

    private var client: (any SFTPClientProtocol)?
    private var configuration: SSHConnectionConfiguration?
    private var usesEphemeralCredentials = false
    private var connectionTask: Task<Void, Never>?
    private var automaticRefreshTask: Task<Void, Never>?
    private var uploadRefreshTask: Task<Void, Never>?
    private var suppliedAuthentications: [Host.ID: SSHAuthenticationSubmission] = [:]
    private var temporaryHostKeys: [Host.ID: SSHHostKeyIdentity] = [:]
    private var connectionAttemptID: UUID?
    private let reconnectController = SessionReconnectController()
    private var hasConnectedOnce = false
    private var isRecoveringConnection = false
    private var operationCancellation: TransferCancellationToken?
    weak var navigationRouter: (any SFTPSessionNavigationRouting)?
    private weak var statusStore: HostLibraryModel?
    private weak var transferCoordinator: SFTPTransferCoordinator?
    weak var historyStore: SFTPHistoryModel?
    private var didResolveInitialPath: Bool
    private let automaticRefreshInterval: Duration
    var connectionCoordinator: RemoteConnectionCoordinator?

    init(
        hostID: Host.ID,
        initialPath: String = "",
        client: (any SFTPClientProtocol)? = nil,
        configuration: SSHConnectionConfiguration? = nil,
        automaticRefreshInterval: Duration = .seconds(15)
    ) {
        self.hostID = hostID
        let configuredPath = initialPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = configuredPath.isEmpty ? "/" : RemotePath.normalized(configuredPath)
        self.initialPath = configuredPath.isEmpty ? "" : path
        self.path = path
        self.pathText = path
        self.client = client
        self.configuration = configuration
        self.didResolveInitialPath = !configuredPath.isEmpty
        self.automaticRefreshInterval = automaticRefreshInterval
        if client != nil { status = .connected }
        if client != nil { hasConnectedOnce = true }
    }

    var reconnectState: ReconnectState? { reconnectController.state }
    var allowsRemoteMutations: Bool { status == .connected }

    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    var conflictCount: Int {
        pendingRemoteCopyBatch?.conflictCount ?? pendingBatch?.conflictCount ?? 0
    }
    /// What the list draws. Already filtered, sorted, and formatted.
    var visibleRows: [SFTPRow] { directoryPresentation.visibleRows }
    /// The same rows as plain files, for selection and menu work. Only ever
    /// reached from event handlers, never from a body pass.
    var filteredFiles: [RemoteFile] { directoryPresentation.visibleRows.map(\.file) }
    var selectedFiles: [RemoteFile] {
        directoryPresentation.visibleRows.filter { selection.contains($0.id) }.map(\.file)
    }

    func sort(by field: SFTPFileSortField) {
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
            hostID: hostID, connection: connection, files: files
        )
    }

    private var transferConnection: SFTPTransferConnection? {
        if usesEphemeralCredentials, let client {
            return .borrowed(id: id, client: client)
        }
        return configuration.map(SFTPTransferConnection.saved)
    }

    func connect(using store: HostLibraryModel) {
        startConnection(using: store)
    }

    func connect(using transfers: TransferLibraryModel) {
        connect(using: transfers.library)
    }

    private func startConnection(using store: HostLibraryModel) {
        let reconnecting = hasConnectedOnce && isRecoveringConnection
        bindStatus(to: store)
        connectionTask?.cancel()
        guard let host = store.host(hostID) else {
            reconnectController.stop()
            isRecoveringConnection = false
            let message = String(localized: "The host is no longer available.")
            status = .failed(message)
            connectionJourney.fail(message)
            return
        }
        let attemptID = UUID()
        connectionAttemptID = attemptID
        let route = store.route(for: host)
        let suppliedAuthentication = suppliedAuthentications[host.id]
        connectionJourney.begin(
            host: host, route: route, purpose: .sftpSession,
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
        hint = reconnecting
            ? String(localized: "Reconnecting") : String(localized: "Connecting")
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let configuration: SSHConnectionConfiguration
                if let suppliedAuthentication {
                    let expectedHostKeys = try store.expectedHostKeys(
                        for: host, temporaryHostKeys: temporaryHostKeys
                    )
                    var credentials: [SSHCredentials] = []
                    if let keyID = suppliedAuthentication.keyID,
                        let key = store.key(keyID), let stored = try? store.keyCredential(for: key)
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
                            temporaryHostKeys: temporaryHostKeys
                        )
                    )
                } else {
                    configuration = try store.sshConnectionConfiguration(
                        for: host, submissions: suppliedAuthentications,
                        temporaryHostKeys: temporaryHostKeys
                    )
                }
                let coordinator = self.connectionCoordinator ?? RemoteConnectionCoordinator()
                let client = try await coordinator.connectSFTP(
                    using: configuration, progress: progressHandler(attemptID: attemptID),
                    connectionFailure: { [weak self] message in
                        Task { @MainActor in
                            self?.handleConnectionFailure(message, attemptID: attemptID)
                        }
                    }
                )
                try Task.checkCancellation()
                try await self.resolveInitialPathIfNeeded(using: client)
                self.connectionJourney.receive(.connected(host.id))
                self.client = client
                self.configuration = self.usesEphemeralCredentials ? nil : configuration
                self.suppliedAuthentications.removeAll()
                self.temporaryHostKeys.removeAll()
                self.pendingAuthentication = nil
                let initialConnection = !self.hasConnectedOnce
                let presentsConnectionJourney = self.connectionJourney.isPresented
                self.hasConnectedOnce = true
                self.isRecoveringConnection = false
                self.reconnectController.markConnected(initial: initialConnection)
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
            } catch TermindSSHError.untrustedHost {
                await self.discoverHostKey(host: host, store: store)
            } catch let error as TermindSSHError where error.isHostKeyChanged {
                store.markKnownHostMismatched(hostname: host.host, port: host.port)
                await self.discoverHostKey(host: host, store: store)
            } catch TermindSSHError.missingCredential,
                TermindSSHError.missingUsername,
                TermindSSHError.keyPassphraseRequired
            {
                self.requestAuthentication(host: host, store: store)
            } catch let error as TermindSSHError where error.shouldRequestHostKey {
                if let id = error.routeHostID, let jump = store.host(id) {
                    await self.discoverHostKey(host: jump, store: store)
                } else {
                    self.status = .failed(error.localizedDescription)
                    self.connectionJourney.fail(error.localizedDescription, at: error.routeHostID)
                }
            } catch let error as TermindSSHError where error.shouldRequestAuthentication {
                let authenticationHost: Host
                if let id = error.routeHostID, let jump = store.host(id) {
                    authenticationHost = jump
                } else {
                    authenticationHost = host
                }
                let submitted = self.suppliedAuthentications[authenticationHost.id]
                let retryNeedsPassphrase = submitted?.passphrase == nil
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
                if self.hasConnectedOnce || reconnecting {
                    self.scheduleReconnect(after: error.localizedDescription, using: store)
                } else {
                    self.status = .failed(error.localizedDescription)
                    self.hint = error.localizedDescription
                    self.connectionJourney.fail(
                        error.localizedDescription, at: self.routeHostID(from: error)
                    )
                }
            }
        }
    }

    func bindStatus(to store: HostLibraryModel) {
        statusStore = store
        store.setConnectionStatus(status, connectionID: id, hostID: hostID)
    }

    func bindTransfers(to coordinator: SFTPTransferCoordinator) {
        transferCoordinator = coordinator
    }

    func disconnect() {
        pendingAuthentication = nil
        pendingHostKey = nil
        pendingHostKeyHostID = nil
        suppliedAuthentications.removeAll()
        temporaryHostKeys.removeAll()
        connectionTask?.cancel()
        connectionTask = nil
        connectionAttemptID = nil
        reconnectController.stop()
        hasConnectedOnce = false
        isRecoveringConnection = false
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        uploadRefreshTask?.cancel()
        uploadRefreshTask = nil
        let client = client
        let transferCoordinator = transferCoordinator
        self.client = nil
        configuration = nil
        usesEphemeralCredentials = false
        status = .disconnected
        connectionJourney.hide()
        replaceDirectoryContents(with: [])
        Task { [id] in
            await transferCoordinator?.cancelTransfers(usingBorrowedConnection: id)
            await client?.disconnect()
        }
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
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        let client = client
        self.client = nil
        configuration = nil
        status = .failed(reconnectState.lastError)
        hint = reconnectState.lastError
        connectionJourney.fail(reconnectState.lastError)
        Task { await client?.disconnect() }
    }

    func resolveInitialPathIfNeeded(using client: any SFTPClientProtocol) async throws {
        guard !didResolveInitialPath else { return }
        path = RemotePath.normalized(try await client.homeDirectory())
        pathText = path
        didResolveInitialPath = true
    }

    func trustAndConnect(_ observation: SSHHostKeyObservation, using store: HostLibraryModel) {
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

    func trustAndConnect(
        _ observation: SSHHostKeyObservation, using transfers: TransferLibraryModel
    ) {
        trustAndConnect(observation, using: transfers.library)
    }

    func continueWithTemporaryHostKey(
        _ observation: SSHHostKeyObservation, using store: HostLibraryModel
    ) {
        guard let hostID = pendingHostKeyHostID else { return }
        temporaryHostKeys[hostID] = observation.identity
        pendingHostKey = nil
        pendingHostKeyHostID = nil
        connectionJourney.resume()
        connect(using: store)
    }

    func continueWithTemporaryHostKey(
        _ observation: SSHHostKeyObservation, using transfers: TransferLibraryModel
    ) {
        continueWithTemporaryHostKey(observation, using: transfers.library)
    }

    func continueAuthentication(
        identityID: Identity.ID?, username: String, password: String?, passphrase: String?,
        keyID: SSHKeyRef.ID?, save: Bool, using store: HostLibraryModel
    ) {
        guard let prompt = pendingAuthentication,
            var host = store.host(prompt.host.id)
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
        let submittedPassword: String?
        do {
            submittedPassword =
                try password
                ?? selectedIdentity.flatMap {
                    try store.passwordCredential(for: $0)
                }
        } catch {
            requestAuthentication(host: host, store: store, failure: error.localizedDescription)
            return
        }

        suppliedAuthentications[host.id] = SSHAuthenticationSubmission(
            username: submittedUsername, password: submittedPassword,
            passphrase: passphrase, keyID: submittedKeyID,
            identityID: selectedIdentity?.id
        )
        usesEphemeralCredentials =
            !save
            && (password != nil || passphrase != nil
                || (selectedIdentity == nil && submittedKeyID == nil))
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
                        operationError = error.localizedDescription
                        requestAuthentication(
                            host: host, store: store, failure: error.localizedDescription
                        )
                        return
                    }
                }
                host.identityID = selectedIdentity.id
                store.upsert(host)
                connect(using: store)
                return
            }
            let existing = store.identity(for: host)
            let identity = Identity(
                id: existing?.id ?? UUID(), name: existing?.name ?? submittedUsername,
                username: submittedUsername, credentialRef: existing?.credentialRef ?? "",
                passwordStorage: existing?.passwordStorage ?? .iCloud,
                keyID: submittedKeyID, notes: existing?.notes ?? "",
                lastUsedAt: existing?.lastUsedAt
            )
            let update: IdentityPasswordUpdate =
                submittedPassword.map(IdentityPasswordUpdate.replace)
                ?? (existing == nil ? .remove : .keep)
            do {
                try store.upsert(identity, passwordUpdate: update)
                var updated = host
                updated.identityID = identity.id
                store.upsert(updated)
            } catch {
                operationError = error.localizedDescription
                requestAuthentication(host: host, store: store, failure: error.localizedDescription)
                return
            }
        }
        connect(using: store)
    }

    func continueAuthentication(
        identityID: Identity.ID?, username: String, password: String?, passphrase: String?,
        keyID: SSHKeyRef.ID?, save: Bool, using transfers: TransferLibraryModel
    ) {
        continueAuthentication(
            identityID: identityID, username: username, password: password,
            passphrase: passphrase, keyID: keyID, save: save, using: transfers.library
        )
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
        guard validFilename(name), let client else { return }
        do {
            try await client.createDirectory(at: RemotePath.join(path, name))
            await reload()
        } catch { operationError = error.localizedDescription }
    }

    func rename(_ file: RemoteFile, to name: String) async {
        guard validFilename(name), let client else { return }
        do {
            try await client.rename(from: file.path, to: RemotePath.join(path, name), overwrite: false)
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
            try await client.setPermissions(at: file.path, to: permissions & 0o7777)
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

    func prepareUpload(_ urls: [URL]) async {
        guard let client else { return }
        var jobs: [PreparedJob] = []
        var directories: [String] = []
        var directoryConflicts: Set<String> = []
        var conflicts = 0
        do {
            for root in urls {
                let scoped = root.startAccessingSecurityScopedResource()
                defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                let values = try root.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let destination = RemotePath.join(path, root.lastPathComponent)
                if values.isDirectory == true {
                    let resolvedRootPath = root.resolvingSymlinksInPath().path
                    let enumerator = FileManager.default.enumerator(
                        at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                        options: [.skipsPackageDescendants]
                    )
                    directories.append(destination)
                    while let item = enumerator?.nextObject() as? URL {
                        let resolvedItemPath = item.resolvingSymlinksInPath().path
                        guard resolvedItemPath.hasPrefix(resolvedRootPath + "/") else { continue }
                        let relative = String(resolvedItemPath.dropFirst(resolvedRootPath.count + 1))
                        let remote = RemotePath.join(destination, relative)
                        let itemValues = try item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                        if itemValues.isDirectory == true {
                            directories.append(remote)
                            continue
                        }
                        jobs.append(
                            PreparedJob(
                                direction: .upload, localURL: item, remotePath: remote,
                                byteCount: Int64(itemValues.fileSize ?? 0), scopedRoot: root,
                                hasConflict: false, conflictingTargetIsDirectory: false
                            ))
                    }
                } else {
                    jobs.append(
                        PreparedJob(
                            direction: .upload, localURL: root, remotePath: destination,
                            byteCount: Int64(values.fileSize ?? 0), scopedRoot: root,
                            hasConflict: false, conflictingTargetIsDirectory: false
                        ))
                }
            }
            let orderedDirectories = directories.sorted { $0.count < $1.count }
            for directory in orderedDirectories {
                if directoryConflicts.contains(where: { directory.hasPrefix($0 + "/") }) {
                    continue
                }
                if let existing = try await client.attributes(at: directory), !existing.isDirectory {
                    directoryConflicts.insert(directory)
                    conflicts += 1
                }
            }
            for index in jobs.indices where jobs[index].direction == .upload {
                if directoryConflicts.contains(where: {
                    jobs[index].remotePath.hasPrefix($0 + "/")
                }) {
                    continue
                }
                if let existing = try await client.attributes(at: jobs[index].remotePath) {
                    jobs[index].hasConflict = true
                    jobs[index].conflictingTargetIsDirectory = existing.isDirectory
                    conflicts += 1
                }
            }
            pendingRemoteCopyBatch = nil
            pendingBatch = PreparedBatch(
                jobs: jobs, remoteDirectories: orderedDirectories,
                remoteDirectoryConflicts: directoryConflicts,
                localDirectories: [], localDirectoryConflicts: [], conflictCount: conflicts
            )
        } catch { operationError = error.localizedDescription }
    }

    func prepareDownload(_ files: [RemoteFile], to directory: URL) async {
        guard let client else { return }
        var jobs: [PreparedJob] = []
        var directories: [URL] = []
        var directoryConflicts: Set<URL> = []
        var conflicts = 0
        do {
            func collect(_ remote: RemoteFile, local: URL) async throws {
                if remote.isDirectory {
                    directories.append(local)
                    for child in try await client.listDirectory(at: remote.path) {
                        try await collect(child, local: local.appendingPathComponent(child.name))
                    }
                } else {
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory)
                    if exists { conflicts += 1 }
                    jobs.append(
                        PreparedJob(
                            direction: .download, localURL: local, remotePath: remote.path,
                            byteCount: remote.size, scopedRoot: directory, hasConflict: exists,
                            conflictingTargetIsDirectory: exists && isDirectory.boolValue
                        ))
                }
            }
            for file in files {
                try await collect(file, local: directory.appendingPathComponent(file.name))
            }
            for directory in directories {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                    !isDirectory.boolValue
                {
                    directoryConflicts.insert(directory)
                    conflicts += 1
                }
            }
            pendingRemoteCopyBatch = nil
            pendingBatch = PreparedBatch(
                jobs: jobs, remoteDirectories: [], remoteDirectoryConflicts: [],
                localDirectories: directories, localDirectoryConflicts: directoryConflicts,
                conflictCount: conflicts
            )
        } catch { operationError = error.localizedDescription }
    }

    func prepareRemoteCopy(
        _ payload: SFTPRemoteItemsPayload,
        coordinator: SFTPTransferCoordinator
    ) async {
        bindTransfers(to: coordinator)
        guard let client else { return }
        do {
            let manifest = try await coordinator.remoteManifest(for: payload)
            var jobs: [PreparedRemoteCopyJob] = []
            var directories: [String] = []
            var directoryConflicts: Set<String> = []
            var conflicts = 0

            for entry in manifest.entries {
                let destination = RemotePath.join(path, entry.relativePath)
                if entry.isDirectory {
                    directories.append(destination)
                } else {
                    jobs.append(
                        PreparedRemoteCopyJob(
                            sourcePath: entry.sourcePath,
                            destinationPath: destination,
                            byteCount: entry.byteCount,
                            hasConflict: false,
                            conflictingTargetIsDirectory: false
                        ))
                }
            }

            let orderedDirectories = directories.sorted { $0.count < $1.count }
            for directory in orderedDirectories {
                if directoryConflicts.contains(where: { directory.hasPrefix($0 + "/") }) {
                    continue
                }
                if let existing = try await client.attributes(at: directory), !existing.isDirectory {
                    directoryConflicts.insert(directory)
                    conflicts += 1
                }
            }
            for index in jobs.indices {
                if directoryConflicts.contains(where: {
                    jobs[index].destinationPath.hasPrefix($0 + "/")
                }) {
                    continue
                }
                if let existing = try await client.attributes(at: jobs[index].destinationPath) {
                    jobs[index].hasConflict = true
                    jobs[index].conflictingTargetIsDirectory = existing.isDirectory
                    conflicts += 1
                }
            }

            pendingBatch = nil
            pendingRemoteCopyBatch = PreparedRemoteCopyBatch(
                source: manifest.source, jobs: jobs,
                remoteDirectories: orderedDirectories,
                remoteDirectoryConflicts: directoryConflicts,
                conflictCount: conflicts
            )
        } catch {
            operationError = error.localizedDescription
        }
    }

    func open(
        _ file: RemoteFile, coordinator: SFTPTransferCoordinator,
        completion: @escaping (URL) -> Void
    ) {
        bindTransfers(to: coordinator)
        guard !file.isDirectory, let connection = transferConnection else { return }
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
                connection: connection, scopedRoot: directory, overwrite: false
            ) { state in
                if state == .completed {
                    completion(localURL)
                }
            }
        } catch { operationError = error.localizedDescription }
    }

    func recordOpenedFile(at path: String) {
        historyStore?.record(kind: .file, path: path, for: hostID)
    }

    func reopenHistoryFile(
        at path: String, coordinator: SFTPTransferCoordinator,
        completion: @escaping (URL) -> Void
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
                open(file, coordinator: coordinator, completion: completion)
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
            overwrite: false
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
        guard let batch = pendingBatch, let connection = transferConnection, let client else {
            return
        }
        pendingBatch = nil
        do {
            var changedRemoteDirectory = false
            var skippedRemotePrefixes: [String] = []
            var remoteMappings: [(String, String)] = []
            for originalDirectory in batch.remoteDirectories {
                if skippedRemotePrefixes.contains(where: {
                    originalDirectory == $0 || originalDirectory.hasPrefix($0 + "/")
                }) {
                    continue
                }
                var directory = originalDirectory
                for mapping in remoteMappings
                where directory == mapping.0 || directory.hasPrefix(mapping.0 + "/") {
                    directory = mapping.1 + directory.dropFirst(mapping.0.count)
                }
                if batch.remoteDirectoryConflicts.contains(originalDirectory) {
                    switch policy {
                    case .skip:
                        skippedRemotePrefixes.append(originalDirectory)
                        continue
                    case .replace:
                        try await client.removeFile(at: originalDirectory)
                        changedRemoteDirectory = true
                    case .keepBoth:
                        var index = 2
                        var candidate = RemotePath.keepBothCandidate(for: originalDirectory, index: index)
                        while try await client.attributes(at: candidate) != nil {
                            index += 1
                            candidate = RemotePath.keepBothCandidate(for: originalDirectory, index: index)
                        }
                        remoteMappings.append((originalDirectory, candidate))
                        directory = candidate
                    }
                }
                if try await client.attributes(at: directory) == nil {
                    try await client.createDirectory(at: directory)
                    changedRemoteDirectory = true
                }
            }
            let localRoots = Set(batch.jobs.filter { $0.direction == .download }.map(\.scopedRoot))
            var skippedLocalPrefixes: [URL] = []
            var localMappings: [(URL, URL)] = []
            for root in localRoots {
                let scoped = root.startAccessingSecurityScopedResource()
                defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                for originalDirectory in batch.localDirectories where originalDirectory.path.hasPrefix(root.path) {
                    if skippedLocalPrefixes.contains(where: {
                        originalDirectory.path == $0.path
                            || originalDirectory.path.hasPrefix($0.path + "/")
                    }) {
                        continue
                    }
                    var directory = originalDirectory
                    for mapping in localMappings
                    where directory.path == mapping.0.path || directory.path.hasPrefix(mapping.0.path + "/") {
                        directory = URL(
                            fileURLWithPath: mapping.1.path + directory.path.dropFirst(mapping.0.path.count))
                    }
                    if batch.localDirectoryConflicts.contains(originalDirectory) {
                        switch policy {
                        case .skip:
                            skippedLocalPrefixes.append(originalDirectory)
                            continue
                        case .replace:
                            try FileManager.default.removeItem(at: originalDirectory)
                        case .keepBoth:
                            let candidate = Self.keepBothLocalURL(originalDirectory)
                            localMappings.append((originalDirectory, candidate))
                            directory = candidate
                        }
                    }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                }
            }
            for var job in batch.jobs {
                if skippedRemotePrefixes.contains(where: { job.remotePath == $0 || job.remotePath.hasPrefix($0 + "/") })
                    || skippedLocalPrefixes.contains(where: {
                        job.localURL.path == $0.path || job.localURL.path.hasPrefix($0.path + "/")
                    })
                {
                    continue
                }
                for mapping in remoteMappings
                where job.remotePath == mapping.0 || job.remotePath.hasPrefix(mapping.0 + "/") {
                    job.remotePath = mapping.1 + job.remotePath.dropFirst(mapping.0.count)
                    job.hasConflict = false
                }
                for mapping in localMappings
                where job.localURL.path == mapping.0.path || job.localURL.path.hasPrefix(mapping.0.path + "/") {
                    let suffix = job.localURL.path.dropFirst(mapping.0.path.count)
                    job.localURL = URL(fileURLWithPath: mapping.1.path + suffix)
                    job.hasConflict = false
                    try FileManager.default.createDirectory(
                        at: job.localURL.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                }
                if job.hasConflict {
                    switch policy {
                    case .skip: continue
                    case .replace:
                        if job.conflictingTargetIsDirectory {
                            if job.direction == .upload,
                                let existing = try await client.attributes(at: job.remotePath)
                            {
                                try await deleteRecursively(existing, client: client)
                            } else if job.direction == .download {
                                try FileManager.default.removeItem(at: job.localURL)
                            }
                        }
                    case .keepBoth:
                        if job.direction == .upload {
                            var index = 2
                            var candidate = RemotePath.keepBothCandidate(for: job.remotePath, index: index)
                            while try await client.attributes(at: candidate) != nil {
                                index += 1
                                candidate = RemotePath.keepBothCandidate(for: job.remotePath, index: index)
                            }
                            job.remotePath = candidate
                        } else {
                            job.localURL = Self.keepBothLocalURL(job.localURL)
                        }
                    }
                }
                let completion: ((SFTPTransfer.State) -> Void)? =
                    job.direction == .upload
                    ? { [weak self] state in
                        if state == .completed { self?.scheduleSilentRefresh() }
                    }
                    : nil
                coordinator.enqueue(
                    direction: job.direction, batchID: batch.id, localURL: job.localURL,
                    remotePath: job.remotePath, byteCount: job.byteCount, hostID: hostID,
                    connection: connection, scopedRoot: job.scopedRoot,
                    overwrite: job.hasConflict && policy == .replace,
                    completion: completion
                )
            }
            if changedRemoteDirectory { scheduleSilentRefresh() }
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
            var changedRemoteDirectory = false
            var skippedPrefixes: [String] = []
            var mappings: [(String, String)] = []

            for originalDirectory in batch.remoteDirectories {
                if skippedPrefixes.contains(where: {
                    originalDirectory == $0 || originalDirectory.hasPrefix($0 + "/")
                }) {
                    continue
                }
                var directory = originalDirectory
                for mapping in mappings
                where directory == mapping.0 || directory.hasPrefix(mapping.0 + "/") {
                    directory = mapping.1 + directory.dropFirst(mapping.0.count)
                }
                if batch.remoteDirectoryConflicts.contains(originalDirectory) {
                    switch policy {
                    case .skip:
                        skippedPrefixes.append(originalDirectory)
                        continue
                    case .replace:
                        try await client.removeFile(at: originalDirectory)
                        changedRemoteDirectory = true
                    case .keepBoth:
                        var index = 2
                        var candidate = RemotePath.keepBothCandidate(
                            for: originalDirectory, index: index
                        )
                        while try await client.attributes(at: candidate) != nil {
                            index += 1
                            candidate = RemotePath.keepBothCandidate(
                                for: originalDirectory, index: index
                            )
                        }
                        mappings.append((originalDirectory, candidate))
                        directory = candidate
                    }
                }
                if try await client.attributes(at: directory) == nil {
                    try await client.createDirectory(at: directory)
                    changedRemoteDirectory = true
                }
            }

            for var job in batch.jobs {
                if skippedPrefixes.contains(where: {
                    job.destinationPath == $0 || job.destinationPath.hasPrefix($0 + "/")
                }) {
                    continue
                }
                for mapping in mappings
                where job.destinationPath == mapping.0
                    || job.destinationPath.hasPrefix(mapping.0 + "/")
                {
                    job.destinationPath =
                        mapping.1
                        + job.destinationPath.dropFirst(mapping.0.count)
                    job.hasConflict = false
                }
                if job.hasConflict {
                    switch policy {
                    case .skip:
                        continue
                    case .replace:
                        if job.conflictingTargetIsDirectory,
                            let existing = try await client.attributes(at: job.destinationPath)
                        {
                            try await deleteRecursively(existing, client: client)
                        }
                    case .keepBoth:
                        var index = 2
                        var candidate = RemotePath.keepBothCandidate(
                            for: job.destinationPath, index: index
                        )
                        while try await client.attributes(at: candidate) != nil {
                            index += 1
                            candidate = RemotePath.keepBothCandidate(
                                for: job.destinationPath, index: index
                            )
                        }
                        job.destinationPath = candidate
                    }
                }

                coordinator.enqueueRemoteCopy(
                    batchID: batch.id,
                    sourcePath: job.sourcePath,
                    sourceHostID: batch.source.hostID,
                    sourceConnection: batch.source.connection,
                    destinationPath: job.destinationPath,
                    destinationHostID: hostID,
                    destinationConnection: destinationConnection,
                    byteCount: job.byteCount,
                    overwrite: job.hasConflict && policy == .replace
                ) { [weak self] state in
                    if state == .completed { self?.scheduleSilentRefresh() }
                }
            }
            if changedRemoteDirectory { scheduleSilentRefresh() }
        } catch {
            operationError = error.localizedDescription
        }
    }

    func copyForBrowsing() -> SFTPSessionModel {
        let copy = SFTPSessionModel(hostID: hostID, initialPath: initialPath)
        copy.connectionCoordinator = connectionCoordinator
        return copy
    }

    private func discoverHostKey(host: Host, store: HostLibraryModel) async {
        do {
            let observation = try await SSHSessionActor.discoverHostKey(
                hostID: host.id, host: host.host, port: host.port,
                proxy: try store.transportProxy(for: host),
                jumps: try store.sshJumpConfigurations(
                    for: host, submissions: suppliedAuthentications,
                    temporaryHostKeys: temporaryHostKeys
                ),
                progress: connectionAttemptID.map(progressHandler(attemptID:))
            )
            status = .disconnected
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
            pendingHostKey = SSHHostKeyPrompt(observation: observation, kind: kind)
            pendingHostKeyHostID = host.id
            reconnectController.pauseForUserInteraction()
            connectionJourney.waitForHostKey(
                at: host.id, fingerprint: observation.fingerprint
            )
        } catch {
            if hasConnectedOnce {
                scheduleReconnect(after: error.localizedDescription, using: store)
            } else {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func requestAuthentication(
        host: Host, store: HostLibraryModel, failure: String? = nil,
        mode: SSHAuthenticationPrompt.Mode = .localIdentity,
        requiresPassphrase: Bool? = nil,
        preserveSubmission: Bool = false
    ) {
        reconnectController.pauseForUserInteraction()
        if !preserveSubmission { suppliedAuthentications[host.id] = nil }
        let identity = store.identity(for: host)
        let submission = suppliedAuthentications[host.id]
        let selectedKeyID = submission?.keyID ?? identity?.keyID
        let username = submission?.username ?? identity?.username ?? ""
        let needsPassphrase = requiresPassphrase
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

    private func handleConnectionFailure(_ message: String, attemptID: UUID?) {
        guard hasConnectedOnce, connectionAttemptID == attemptID,
            let store = statusStore
        else { return }
        scheduleReconnect(after: message, using: store)
    }

    private func scheduleReconnect(after message: String, using store: HostLibraryModel) {
        isRecoveringConnection = true
        connectionAttemptID = nil
        connectionTask?.cancel()
        connectionTask = nil
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        uploadRefreshTask?.cancel()
        uploadRefreshTask = nil
        let client = client
        self.client = nil
        configuration = nil
        status = .reconnecting
        hint = String(localized: "Reconnecting")
        presentReconnectJourney(using: store)
        reconnectController.schedule(after: message) { [weak self, weak store] in
            guard let self, let store else { return }
            self.startConnection(using: store)
        }
        Task { await client?.disconnect() }
    }

    private func presentReconnectJourney(using store: HostLibraryModel) {
        guard let host = store.host(hostID) else { return }
        connectionJourney.begin(
            host: host, route: store.route(for: host), purpose: .sftpSession,
            username: store.identity(for: host)?.username, mode: .reconnection
        )
    }

    private func deleteRecursively(
        _ file: RemoteFile, client: any SFTPClientProtocol,
        cancellation: TransferCancellationToken? = nil
    ) async throws {
        if cancellation?.isCancelled == true { throw SFTPError.cancelled }
        hint = file.path
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

    private func validFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private static func keepBothLocalURL(_ url: URL) -> URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension()
        var index = 2
        while true {
            let name =
                ext.isEmpty
                ? "\(base.lastPathComponent).\(index)"
                : "\(base.lastPathComponent).\(index).\(ext)"
            let candidate = base.deletingLastPathComponent().appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}

// MARK: - Demo data

extension SFTPSessionModel {
    /// A populated browser backed only by value data. It deliberately has no
    /// client, so screenshot and preview work can never mutate a remote host.
    static func demo(hostID: Host.ID, path: String = "/etc/nginx") -> SFTPSessionModel {
        let session = SFTPSessionModel(hostID: hostID, initialPath: path)
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
