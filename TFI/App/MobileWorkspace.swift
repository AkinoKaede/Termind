import Foundation
import GhosttyTerminal
import Observation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindRemoteInfrastructure

import struct TermindDomain.Host

@MainActor
@Observable
final class MobileWorkspace: Identifiable {
    let descriptor: MobileWorkspaceDescriptor
    var id: UUID { descriptor.id }
    var detectedDistribution: DetectedDistribution? { hosts.host(descriptor.hostID)?.detectedDistribution }
    var didChangeState: (() -> Void)?
    private(set) var status = String(localized: "Disconnected") { didSet { didChangeState?() } }
    private(set) var connected = false { didSet { didChangeState?() } }
    private(set) var busy = false
    let journey = ConnectionJourney()
    var error: String?
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
    let terminalSettings: TerminalSettingsModel
    let commandHistory: CommandHistoryModel
    var isFindPresented = false
    var findQuery = ""
    private var activeHistoryID: UUID?
    private var shellIntegrationAvailable = false
    private let surfaceOwner = MobileTerminalSurface()
    let terminal: TerminalViewState
    private let backend: InMemoryTerminalSession
    private var ssh: SSHSessionActor?
    private var sftp: (any SFTPClientProtocol)?
    private var attempt: Task<Void, Never>?
    private var generation = UUID()
    private let hosts: any RemoteSessionHostStore
    private var viewport = InMemoryTerminalViewport(columns: 80, rows: 24)

    init(
        descriptor: MobileWorkspaceDescriptor, hosts: any RemoteSessionHostStore,
        transfers: SFTPTransferCoordinator? = nil,
        terminalSettings: TerminalSettingsModel = TerminalSettingsModel(),
        commandHistory: CommandHistoryModel = CommandHistoryModel()
    ) {
        self.terminalSettings = terminalSettings
        self.commandHistory = commandHistory
        self.transfers = transfers
        self.descriptor = descriptor
        self.hosts = hosts
        let relay = MobileTerminalRelay()
        backend = InMemoryTerminalSession(
            write: { data in Task { @MainActor in await relay.owner?.ssh?.write(data) } },
            resize: { size in Task { @MainActor in await relay.owner?.resize(size) } },
            suppressesPixelOnlyResizes: true
        )
        terminal = TerminalViewState(configSource: .none)
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(backend), resizeThrottleMilliseconds: 35)
        let owner = surfaceOwner
        terminal.makePlatformView = { owner.view }
        terminal.inputAccessoryItems = []
        relay.owner = self
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
            selectedKeyID: keyID, failureMessage: error,
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
                    self.error = error.localizedDescription
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

    func receiveShellEvent(_ event: SSHShellIntegrationEvent) {
        guard terminalSettings.preferences.shellIntegration else {
            activeHistoryID = nil
            shellIntegrationAvailable = false
            return
        }
        switch event {
        case .available(_, let systemInfo, _):
            shellIntegrationAvailable = true
            hosts.recordRemoteSystemInfo(systemInfo, for: descriptor.hostID)
        case .systemInfo(let systemInfo): hosts.recordRemoteSystemInfo(systemInfo, for: descriptor.hostID)
        case .commandStarted(let command):
            guard shellIntegrationAvailable else { return }
            activeHistoryID = commandHistory.record(command, for: descriptor.hostID)?.id
        case .commandFinished(let status, let duration):
            guard let id = activeHistoryID else { return }
            commandHistory.recordCompletion(for: id, hostID: descriptor.hostID, exitStatus: status, duration: duration)
            activeHistoryID = nil
        default: break
        }
    }

    func connect() {
        guard !busy, !connected else { return }
        let token = UUID()
        generation = token
        activeHistoryID = nil
        shellIntegrationAvailable = false
        busy = true
        error = nil
        status = String(localized: "Connecting")
        attempt = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { busy = false } }
            do {
                guard let host = hosts.host(descriptor.hostID) else { throw CocoaError(.fileNoSuchFile) }
                journey.begin(
                    host: host, route: hosts.route(for: host),
                    purpose: descriptor.kind == .ssh ? .sshSession : .sftpSession,
                    username: hosts.identity(for: host)?.username)
                // Validate each hop in order so credentials and trust prompts name the actual endpoint.
                for endpoint in hosts.route(for: host) {
                    let preparation = try preparation(for: endpoint)
                    let discovery = try await preparation.resolve(discoveryOnly: true)
                    journey.receive(.connecting(endpoint.id))
                    let observation = try await SSHSessionActor.discoverHostKey(
                        hostID: endpoint.id, host: endpoint.host, port: endpoint.port,
                        proxy: discovery.proxy, jumps: discovery.jumps)
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
                    let session = SSHSessionActor(
                        output: { backend.receive($0) },
                        exit: { [weak self] result in
                            Task { @MainActor in
                                guard let self, self.generation == token else { return }
                                self.generation = UUID()
                                self.attempt?.cancel()
                                self.busy = false
                                self.connected = false
                                self.status = String(localized: "Disconnected")
                                if case .failure(let failure) = result { self.error = failure.localizedDescription }
                            }
                        },
                        shellIntegration: { [weak self] event in
                            Task { @MainActor in
                                guard let self, self.generation == token else { return }
                                self.receiveShellEvent(event)
                                self.didChangeState?()
                            }
                        })
                    ssh = session
                    try await session.connect(
                        hostID: config.hostID, host: config.host, port: config.port,
                        username: config.username, credentials: config.credentials,
                        expectedHostKeys: config.expectedHostKeys,
                        proxy: config.proxy, jumps: config.jumps,
                        shellIntegrationEnabled: terminalSettings.preferences.shellIntegration,
                        columns: UInt16(clamping: viewport.columns),
                        rows: UInt16(clamping: viewport.rows),
                        progress: { [weak self] event in
                            Task { @MainActor in
                                guard let self, self.generation == token else { return }
                                self.journey.receive(event)
                            }
                        })
                } else {
                    let client = try await RemoteConnectionCoordinator().connectSFTP(using: config)
                    guard generation == token, !Task.isCancelled else {
                        await client.disconnect()
                        return
                    }
                    sftp = client
                    path =
                        host.sftpSessionInitialPath.isEmpty
                        ? try await client.homeDirectory() : host.sftpSessionInitialPath
                    files = try await client.listDirectory(at: path)
                }
                guard generation == token, !Task.isCancelled else { return }
                transferConfiguration = config
                submissions.removeAll()
                connected = true
                status = String(localized: "Connected")
                journey.succeed()
            } catch {
                guard generation == token else { return }
                self.error = error.localizedDescription
                journey.fail(error.localizedDescription)
                status = String(localized: "Disconnected")
                if let sshError = error as? TermindSSHError {
                    switch sshError {
                    case .missingCredential, .missingUsername, .keyPassphraseRequired, .authenticationFailed:
                        authenticationRequired = true
                    default: authenticationRequired = sshError.shouldRequestAuthentication
                    }
                    if authenticationRequired {
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
                }
                await ssh?.disconnect()
                await sftp?.disconnect()
                ssh = nil
                sftp = nil
            }
        }
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
        journey.hide()
        pendingHostKey = nil
        authenticationRequired = false
        authenticationPrompt = nil
        temporaryKeys.removeAll()
        submissions.removeAll()

        activeHistoryID = nil
        shellIntegrationAvailable = false
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

    func openDirectory(_ directory: String) async {
        guard let sftp else { return }
        let connection = generation
        let request = UUID()
        directoryRequest = request
        do {
            let entries = try await sftp.listDirectory(at: directory)
            guard generation == connection, directoryRequest == request else { return }
            path = directory
            files = entries.sorted { ($0.isDirectory ? 0 : 1, $0.name) < ($1.isDirectory ? 0 : 1, $1.name) }
        } catch {
            guard generation == connection, directoryRequest == request else { return }
            self.error = error.localizedDescription
        }
    }

    func rename(_ file: RemoteFile, to name: String) async throws {
        guard validName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        guard let sftp else { throw TermindSSHError.disconnected }
        let connection = generation
        try await sftp.rename(
            from: file.path, to: RemotePath.join(RemotePath.parent(of: file.path), name), overwrite: false)
        guard connection == generation else { throw CancellationError() }
        await openDirectory(path)
    }

    func setPermissions(_ file: RemoteFile, mode: UInt32) async throws {
        guard let sftp else { throw TermindSSHError.disconnected }
        let connection = generation
        try await sftp.setPermissions(at: file.path, to: mode & 0o7777)
        guard connection == generation else { throw CancellationError() }
        await openDirectory(path)
    }

    func createDirectory(_ name: String) async {
        guard let sftp, validName(name) else { return }
        do {
            try await sftp.createDirectory(at: RemotePath.join(path, name))
            await openDirectory(path)
        } catch { self.error = error.localizedDescription }
    }

    func delete(_ file: RemoteFile) async {
        guard let sftp else { return }
        do {
            if file.isDirectory {
                try await sftp.removeDirectory(at: file.path)
            } else {
                try await sftp.removeFile(at: file.path)
            }
            await openDirectory(path)
        } catch { self.error = error.localizedDescription }
    }

    func upload(_ url: URL) async {
        guard let transfers, let configuration = transferConfiguration, connected else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard validName(url.lastPathComponent) else { throw CocoaError(.fileReadInvalidFileName) }
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard attributes.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
            let connection = generation
            transfers.enqueue(
                direction: .upload, batchID: UUID(), localURL: url,
                remotePath: RemotePath.join(path, url.lastPathComponent), byteCount: Int64(attributes.fileSize ?? 0),
                hostID: descriptor.hostID, configuration: configuration, scopedRoot: url, overwrite: false,
                completion: { [weak self] state in
                    guard let self, self.generation == connection, state == .completed else { return }
                    Task { await self.openDirectory(self.path) }
                })
        } catch { self.error = error.localizedDescription }
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
        } catch { self.error = error.localizedDescription }
    }

    private func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
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
