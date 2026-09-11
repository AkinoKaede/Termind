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
    var error: String?
    var pendingHostKey: SSHHostKeyObservation?
    var authenticationRequired = false
    var username = ""
    var password = ""
    var passphrase = ""
    var authenticationHostName: String {
        hosts.host(authenticationHostID ?? descriptor.hostID)?.name ?? descriptor.title
    }
    private var authenticationHostID: UUID?
    private var submissions: [UUID: SSHAuthenticationSubmission] = [:]
    var path = "/"
    private(set) var files: [RemoteFile] = []
    let transfers: SFTPTransferCoordinator?
    private var transferConfiguration: SSHConnectionConfiguration?
    private var directoryRequest = UUID()
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
        transfers: SFTPTransferCoordinator? = nil
    ) {
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

    func connect() {
        guard !busy, !connected else { return }
        let token = UUID()
        generation = token
        busy = true
        error = nil
        status = String(localized: "Connecting")
        attempt = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { busy = false } }
            do {
                guard let host = hosts.host(descriptor.hostID) else { throw CocoaError(.fileNoSuchFile) }
                // Validate each hop in order so credentials and trust prompts name the actual endpoint.
                for endpoint in hosts.route(for: host) {
                    let preparation = try hosts.prepareSSHConnection(for: endpoint, submissions: submissions)
                    let discovery = try await preparation.resolve(discoveryOnly: true)
                    let observation = try await SSHSessionActor.discoverHostKey(
                        hostID: endpoint.id, host: endpoint.host, port: endpoint.port,
                        proxy: discovery.proxy, jumps: discovery.jumps)
                    guard generation == token, !Task.isCancelled else { return }
                    let trusted = hosts.knownHosts(for: endpoint)
                    if !trusted.contains(where: { $0.identity == observation.identity }) {
                        if trusted.contains(where: { $0.algorithm == observation.algorithm }) {
                            hosts.markKnownHostMismatched(hostname: endpoint.host, port: endpoint.port)
                            throw TermindSSHError.hostKeyChanged(
                                expected: trusted.map(\.fingerprint), received: observation.fingerprint)
                        }
                        pendingHostKey = observation
                        status = String(localized: "Waiting for approval")
                        return
                    }
                }
                let preparation = try hosts.prepareSSHConnection(for: host, submissions: submissions)
                let config = try await preparation.resolve()
                guard generation == token, !Task.isCancelled else { return }
                password = ""
                passphrase = ""
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
                                switch event {
                                case .available(_, let systemInfo, _):
                                    self.hosts.recordRemoteSystemInfo(systemInfo, for: self.descriptor.hostID)
                                case .systemInfo(let systemInfo):
                                    self.hosts.recordRemoteSystemInfo(systemInfo, for: self.descriptor.hostID)
                                default: return
                                }
                                self.didChangeState?()
                            }
                        })
                    ssh = session
                    try await session.connect(
                        hostID: config.hostID, host: config.host, port: config.port,
                        username: config.username, credentials: config.credentials,
                        expectedHostKeys: config.expectedHostKeys,
                        proxy: config.proxy, jumps: config.jumps, columns: UInt16(clamping: viewport.columns),
                        rows: UInt16(clamping: viewport.rows))
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
            } catch {
                guard generation == token else { return }
                self.error = error.localizedDescription
                status = String(localized: "Disconnected")
                if let sshError = error as? TermindSSHError {
                    switch sshError {
                    case .missingCredential, .missingUsername, .keyPassphraseRequired, .authenticationFailed:
                        authenticationRequired = true
                    default: authenticationRequired = sshError.shouldRequestAuthentication
                    }
                    if authenticationRequired {
                        authenticationHostID = sshError.routeHostID ?? descriptor.hostID
                        if let endpoint = hosts.host(authenticationHostID ?? descriptor.hostID) {
                            username =
                                submissions[endpoint.id]?.username ?? hosts.identity(for: endpoint)?.username ?? ""
                        }
                        password = ""
                        passphrase = ""
                    }
                }
                await ssh?.disconnect()
                await sftp?.disconnect()
                ssh = nil
                sftp = nil
            }
        }
    }

    func submitAuthentication() {
        let id = authenticationHostID ?? descriptor.hostID
        guard let host = hosts.host(id) else { return }
        submissions[id] = SSHAuthenticationSubmission(
            username: username,
            password: password.isEmpty ? nil : password, passphrase: passphrase.isEmpty ? nil : passphrase,
            keyID: hosts.identity(for: host)?.keyID)
        password = ""
        passphrase = ""
        authenticationRequired = false
        connect()
    }

    func cancelAuthentication() {
        password = ""
        passphrase = ""
        submissions.removeAll()
        authenticationRequired = false
    }

    func trustHostKey() {
        guard let observation = pendingHostKey else { return }
        hosts.trust(
            KnownHostEntry(
                hostname: observation.hostname, port: observation.port,
                algorithm: observation.algorithm, fingerprint: observation.fingerprint, addedAt: .now))
        pendingHostKey = nil
        connect()
    }

    func disconnect() {
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
        password = ""
        passphrase = ""
        submissions.removeAll()
        authenticationRequired = false
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
