import Foundation

nonisolated struct SFTPRemoteItemsPayload: Codable, Hashable, Sendable {
    var token: UUID
}

nonisolated enum SFTPTransferConnection: Sendable {
    case saved(SSHConnectionConfiguration)
    case borrowed(id: UUID, client: any SFTPClientProtocol)

    var borrowedID: UUID? {
        if case .borrowed(let id, _) = self { id } else { nil }
    }
}

nonisolated struct SFTPRemoteCopySource: Sendable {
    var hostID: Host.ID
    var connection: SFTPTransferConnection
    var files: [RemoteFile]

    init(hostID: Host.ID, connection: SFTPTransferConnection, files: [RemoteFile]) {
        self.hostID = hostID
        self.connection = connection
        self.files = files
    }

    init(hostID: Host.ID, configuration: SSHConnectionConfiguration, files: [RemoteFile]) {
        self.init(hostID: hostID, connection: .saved(configuration), files: files)
    }
}

nonisolated struct SFTPRemoteManifestEntry: Sendable {
    var sourcePath: String
    var relativePath: String
    var kind: RemoteFile.Kind
    var byteCount: Int64

    var isDirectory: Bool { kind == .directory }
}

nonisolated enum TransferConflictPolicy: String, CaseIterable, Identifiable, Sendable {
    case replace, skip, keepBoth
    var id: String { rawValue }
}

nonisolated struct SFTPTransferSummary: Equatable, Sendable {
    var activeCount: Int
    var failedCount: Int
    var aggregateProgress: Double?
}

nonisolated enum RemotePath {
    static func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        var components: [Substring] = []
        for component in trimmed.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    static func join(_ base: String, _ name: String) -> String {
        let base = normalized(base)
        return base == "/" ? "/\(name)" : "\(base)/\(name)"
    }

    static func parent(of path: String) -> String {
        let value = normalized(path)
        guard value != "/" else { return "/" }
        let parent = (value as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func keepBothCandidate(for path: String, index: Int) -> String {
        let ns = path as NSString
        let parent = ns.deletingLastPathComponent
        let name = ns.lastPathComponent as NSString
        let ext = name.pathExtension
        let stem = name.deletingPathExtension
        let candidate = ext.isEmpty ? "\(stem).\(index)" : "\(stem).\(index).\(ext)"
        return parent == "/" ? "/\(candidate)" : "\(parent)/\(candidate)"
    }
}

@Observable
final class SFTPTransferCoordinator {
    typealias ClientFactory = @Sendable () -> any SFTPClientProtocol

    private struct Runtime {
        var connection: SFTPTransferConnection
        var localURL: URL
        var remotePath: String
        var overwrite: Bool
        var scopedRoot: URL
        var cancellation: TransferCancellationToken
        var completion: ((SFTPTransfer.State) -> Void)?
    }

    private struct RemoteCopyRuntime {
        var sourceHostID: Host.ID
        var sourceConnection: SFTPTransferConnection
        var sourcePath: String
        var destinationHostID: Host.ID
        var destinationConnection: SFTPTransferConnection
        var destinationPath: String
        var overwrite: Bool
        var cancellation: TransferCancellationToken
        var completion: ((SFTPTransfer.State) -> Void)?
    }

    private let store: HostLibraryModel
    private let clientFactory: ClientFactory
    private var runtimes: [SFTPTransfer.ID: Runtime] = [:]
    private var remoteCopyRuntimes: [SFTPTransfer.ID: RemoteCopyRuntime] = [:]
    private var activeTasks: [SFTPTransfer.ID: Task<Void, Never>] = [:]
    private var activePerHost: [Host.ID: Int] = [:]
    private var activeBorrowedConnections: Set<UUID> = []
    private var remoteCopySources: [UUID: (source: SFTPRemoteCopySource, createdAt: Date)] = [:]

    private(set) var globalLimit: Int
    private(set) var perHostLimit: Int

    init(
        store: HostLibraryModel,
        clientFactory: @escaping ClientFactory,
        globalLimit: Int? = nil, perHostLimit: Int? = nil
    ) {
        self.store = store
        self.clientFactory = clientFactory
        let defaults = UserDefaults.standard
        self.globalLimit = Self.normalizedLimit(
            globalLimit ?? defaults.object(forKey: SettingsKey.sftpGlobalTransferLimit) as? Int
                ?? SettingsKey.defaultSFTPGlobalTransferLimit
        )
        self.perHostLimit = Self.normalizedLimit(
            perHostLimit ?? defaults.object(forKey: SettingsKey.sftpPerHostTransferLimit) as? Int
                ?? SettingsKey.defaultSFTPPerHostTransferLimit
        )
    }

    func updateLimits(global: Int, perHost: Int) {
        globalLimit = Self.normalizedLimit(global)
        perHostLimit = min(Self.normalizedLimit(perHost), globalLimit)
        schedule()
    }

    private static func normalizedLimit(_ value: Int) -> Int { min(max(value, 1), 8) }

    var sftpTransfers: [SFTPTransfer] {
        store.sftpTransfers.sorted { $0.queuedAt < $1.queuedAt }
    }
    var activeCount: Int { activeTasks.count }
    var summary: SFTPTransferSummary {
        let active = sftpTransfers.filter { $0.state == .queued || $0.state == .running }
        let failedCount = sftpTransfers.filter {
            if case .failed = $0.state { true } else { false }
        }.count
        let measurable = active.filter { $0.byteCount > 0 }
        let total = measurable.reduce(Int64(0)) { $0 + $1.byteCount }
        let completed = measurable.reduce(Int64(0)) {
            $0 + min($1.transferredBytes, $1.byteCount)
        }
        let aggregateProgress: Double?
        if total > 0 {
            aggregateProgress = min(1, Double(completed) / Double(total))
        } else {
            aggregateProgress = nil
        }
        return SFTPTransferSummary(
            activeCount: active.count,
            failedCount: failedCount,
            aggregateProgress: aggregateProgress
        )
    }

    func registerRemoteCopySource(_ source: SFTPRemoteCopySource) -> SFTPRemoteItemsPayload {
        let expiration = Date().addingTimeInterval(-60 * 60)
        remoteCopySources = remoteCopySources.filter { $0.value.createdAt > expiration }
        let payload = SFTPRemoteItemsPayload(token: UUID())
        remoteCopySources[payload.token] = (source, Date())
        return payload
    }

    func remoteCopySource(for payload: SFTPRemoteItemsPayload) -> SFTPRemoteCopySource? {
        remoteCopySources[payload.token]?.source
    }

    func remoteManifest(for payload: SFTPRemoteItemsPayload) async throws
        -> (source: SFTPRemoteCopySource, entries: [SFTPRemoteManifestEntry])
    {
        guard let source = remoteCopySource(for: payload) else {
            throw SFTPError.operation("The copied SFTP items are no longer available.")
        }
        let borrowedID = source.connection.borrowedID
        if let borrowedID {
            try await reserveBorrowedConnection(borrowedID)
        }
        defer {
            if let borrowedID { releaseBorrowedConnections([borrowedID]) }
        }
        let client: any SFTPClientProtocol
        let ownsConnection: Bool
        switch source.connection {
        case .saved(let configuration):
            client = clientFactory()
            ownsConnection = true
            try await client.connect(using: configuration, progress: nil)
        case .borrowed(_, let borrowed):
            client = borrowed
            ownsConnection = false
        }
        do {
            var entries: [SFTPRemoteManifestEntry] = []
            func collect(_ file: RemoteFile, relativePath: String) async throws {
                entries.append(
                    SFTPRemoteManifestEntry(
                        sourcePath: file.path, relativePath: relativePath,
                        kind: file.kind, byteCount: file.size
                    ))
                guard file.isDirectory else { return }
                for child in try await client.listDirectory(at: file.path) {
                    try await collect(
                        child,
                        relativePath: relativePath + "/" + child.name
                    )
                }
            }
            for file in source.files {
                try await collect(file, relativePath: file.name)
            }
            if ownsConnection { await client.disconnect() }
            return (source, entries)
        } catch {
            if ownsConnection { await client.disconnect() }
            throw error
        }
    }

    func enqueue(
        direction: SFTPTransfer.Direction, batchID: UUID,
        localURL: URL, remotePath: String, byteCount: Int64,
        hostID: Host.ID, connection: SFTPTransferConnection,
        scopedRoot: URL, overwrite: Bool,
        completion: ((SFTPTransfer.State) -> Void)? = nil
    ) {
        let sftpTransfer = SFTPTransfer(
            batchID: batchID, hostID: hostID,
            sourceHostID: direction == .download ? hostID : nil,
            destinationHostID: direction == .upload ? hostID : nil,
            direction: direction,
            localPath: localURL.path, remotePath: remotePath,
            byteCount: byteCount, queuedAt: Date()
        )
        store.enqueueSFTPTransfer(sftpTransfer)
        runtimes[sftpTransfer.id] = Runtime(
            connection: connection, localURL: localURL,
            remotePath: remotePath, overwrite: overwrite,
            scopedRoot: scopedRoot, cancellation: TransferCancellationToken(),
            completion: completion
        )
        schedule()
    }

    func enqueue(
        direction: SFTPTransfer.Direction, batchID: UUID,
        localURL: URL, remotePath: String, byteCount: Int64,
        hostID: Host.ID, configuration: SSHConnectionConfiguration,
        scopedRoot: URL, overwrite: Bool,
        completion: ((SFTPTransfer.State) -> Void)? = nil
    ) {
        enqueue(
            direction: direction, batchID: batchID, localURL: localURL,
            remotePath: remotePath, byteCount: byteCount, hostID: hostID,
            connection: .saved(configuration), scopedRoot: scopedRoot,
            overwrite: overwrite, completion: completion
        )
    }

    func enqueueRemoteCopy(
        batchID: UUID,
        sourcePath: String, sourceHostID: Host.ID,
        sourceConnection: SFTPTransferConnection,
        destinationPath: String, destinationHostID: Host.ID,
        destinationConnection: SFTPTransferConnection,
        byteCount: Int64, overwrite: Bool,
        completion: ((SFTPTransfer.State) -> Void)? = nil
    ) {
        let sftpTransfer = SFTPTransfer(
            batchID: batchID, hostID: destinationHostID,
            sourceHostID: sourceHostID, destinationHostID: destinationHostID,
            direction: .copy,
            localPath: sourcePath, remotePath: destinationPath,
            byteCount: byteCount, queuedAt: Date()
        )
        store.enqueueSFTPTransfer(sftpTransfer)
        remoteCopyRuntimes[sftpTransfer.id] = RemoteCopyRuntime(
            sourceHostID: sourceHostID,
            sourceConnection: sourceConnection,
            sourcePath: sourcePath,
            destinationHostID: destinationHostID,
            destinationConnection: destinationConnection,
            destinationPath: destinationPath,
            overwrite: overwrite,
            cancellation: TransferCancellationToken(),
            completion: completion
        )
        schedule()
    }

    func enqueueRemoteCopy(
        batchID: UUID,
        sourcePath: String, sourceHostID: Host.ID,
        sourceConfiguration: SSHConnectionConfiguration,
        destinationPath: String, destinationHostID: Host.ID,
        destinationConfiguration: SSHConnectionConfiguration,
        byteCount: Int64, overwrite: Bool,
        completion: ((SFTPTransfer.State) -> Void)? = nil
    ) {
        enqueueRemoteCopy(
            batchID: batchID, sourcePath: sourcePath, sourceHostID: sourceHostID,
            sourceConnection: .saved(sourceConfiguration),
            destinationPath: destinationPath, destinationHostID: destinationHostID,
            destinationConnection: .saved(destinationConfiguration),
            byteCount: byteCount, overwrite: overwrite, completion: completion
        )
    }

    func cancel(_ id: SFTPTransfer.ID) {
        guard let sftpTransfer = store.sftpTransfer(id) else { return }
        if sftpTransfer.state == .queued {
            runtimes.removeValue(forKey: id)
            remoteCopyRuntimes.removeValue(forKey: id)
            store.finishSFTPTransfer(id, state: .cancelled)
        } else {
            if let runtime = runtimes[id] {
                runtime.cancellation.cancel()
            } else {
                remoteCopyRuntimes[id]?.cancellation.cancel()
            }
        }
    }

    func cancelAll() {
        let ids = store.sftpTransfers.compactMap { sftpTransfer -> SFTPTransfer.ID? in
            switch sftpTransfer.state {
            case .queued, .running: sftpTransfer.id
            case .paused, .completed, .failed, .cancelled: nil
            }
        }
        for id in ids { cancel(id) }
    }

    func cancelAll(for hostID: Host.ID) {
        for transfer in store.sftpTransfers where transfer.involves(hostID) {
            cancel(transfer.id)
        }
    }

    func cancelTransfers(usingBorrowedConnection connectionID: UUID) async {
        let ids = store.sftpTransfers.compactMap { transfer -> SFTPTransfer.ID? in
            guard transfer.state == .queued || transfer.state == .running,
                borrowedIDs(for: transfer).contains(connectionID)
            else { return nil }
            return transfer.id
        }
        for id in ids { cancel(id) }
        while activeBorrowedConnections.contains(connectionID) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func clearFinished() { store.clearFinishedSFTPTransfers() }

    private func schedule() {
        while activeTasks.count < globalLimit {
            guard
                let sftpTransfer = store.sftpTransfers.first(where: { sftpTransfer in
                    guard sftpTransfer.state == .queued,
                        runtimes[sftpTransfer.id] != nil || remoteCopyRuntimes[sftpTransfer.id] != nil
                    else { return false }
                    let borrowedIDs = borrowedIDs(for: sftpTransfer)
                    guard borrowedIDs.allSatisfy({ !activeBorrowedConnections.contains($0) }) else {
                        return false
                    }
                    return hostIDs(for: sftpTransfer).allSatisfy {
                        activePerHost[$0, default: 0] < perHostLimit
                    }
                })
            else { return }
            start(sftpTransfer)
        }
    }

    private func start(_ sftpTransfer: SFTPTransfer) {
        if let runtime = remoteCopyRuntimes[sftpTransfer.id] {
            startRemoteCopy(sftpTransfer, runtime: runtime)
            return
        }
        guard let hostID = sftpTransfer.hostID, let runtime = runtimes[sftpTransfer.id] else { return }
        store.setSFTPTransferState(.running, for: sftpTransfer.id)
        activePerHost[hostID, default: 0] += 1
        let borrowedIDs = Array(runtime.connection.borrowedID.map { [$0] } ?? [])
        activeBorrowedConnections.formUnion(borrowedIDs)
        let task = Task { [weak self] in
            guard let self else { return }
            let scoped = runtime.scopedRoot.startAccessingSecurityScopedResource()
            defer { if scoped { runtime.scopedRoot.stopAccessingSecurityScopedResource() } }
            let client: any SFTPClientProtocol
            let ownsConnection: Bool
            let result: SFTPTransfer.State
            do {
                switch runtime.connection {
                case .saved(let configuration):
                    client = clientFactory()
                    ownsConnection = true
                    try await client.connect(using: configuration, progress: nil)
                case .borrowed(_, let borrowed):
                    client = borrowed
                    ownsConnection = false
                }
                let progress: @Sendable (SFTPProgress) -> Void = { [weak self] value in
                    Task { @MainActor in
                        self?.store.updateSFTPTransfer(
                            sftpTransfer.id, completedBytes: value.completedBytes,
                            totalBytes: value.totalBytes, bytesPerSecond: value.bytesPerSecond
                        )
                    }
                }
                switch sftpTransfer.direction {
                case .upload:
                    try await client.uploadFile(
                        from: runtime.localURL, to: runtime.remotePath,
                        overwrite: runtime.overwrite, cancellation: runtime.cancellation,
                        progress: progress
                    )
                case .download:
                    try FileManager.default.createDirectory(
                        at: runtime.localURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try await client.downloadFile(
                        from: runtime.remotePath, to: runtime.localURL,
                        overwrite: runtime.overwrite, cancellation: runtime.cancellation,
                        progress: progress
                    )
                case .copy:
                    throw SFTPError.operation("Invalid copy transfer runtime.")
                }
                result = .completed
            } catch SFTPError.cancelled {
                result = .cancelled
            } catch is CancellationError {
                result = .cancelled
            } catch {
                result = .failed(error.localizedDescription)
            }
            if ownsConnection { await client.disconnect() }
            finish(
                sftpTransfer.id, hostIDs: [hostID], borrowedIDs: borrowedIDs,
                state: result
            )
        }
        activeTasks[sftpTransfer.id] = task
    }

    private func startRemoteCopy(_ sftpTransfer: SFTPTransfer, runtime: RemoteCopyRuntime) {
        let involvedHostIDs = Array(Set([runtime.sourceHostID, runtime.destinationHostID]))
        store.setSFTPTransferState(.running, for: sftpTransfer.id)
        for hostID in involvedHostIDs { activePerHost[hostID, default: 0] += 1 }
        let borrowedIDs = [
            runtime.sourceConnection.borrowedID,
            runtime.destinationConnection.borrowedID,
        ].compactMap { $0 }
        activeBorrowedConnections.formUnion(borrowedIDs)
        let task = Task { [weak self] in
            guard let self else { return }
            let source: any SFTPClientProtocol
            var destination: (any SFTPClientProtocol)?
            let ownsSource: Bool
            var ownsDestination = false
            let result: SFTPTransfer.State
            do {
                switch runtime.sourceConnection {
                case .saved(let configuration):
                    source = clientFactory()
                    ownsSource = true
                    try await source.connect(using: configuration, progress: nil)
                case .borrowed(_, let client):
                    source = client
                    ownsSource = false
                }
                switch runtime.destinationConnection {
                case .saved(let configuration):
                    let client = clientFactory()
                    destination = client
                    ownsDestination = true
                    try await client.connect(using: configuration, progress: nil)
                case .borrowed(_, let client):
                    destination = client
                    ownsDestination = false
                }
                guard let destination else { throw SFTPError.notConnected }
                let progress: @Sendable (SFTPProgress) -> Void = { [weak self] value in
                    Task { @MainActor in
                        self?.store.updateSFTPTransfer(
                            sftpTransfer.id, completedBytes: value.completedBytes,
                            totalBytes: value.totalBytes,
                            bytesPerSecond: value.bytesPerSecond
                        )
                    }
                }
                try await source.copyFile(
                    from: runtime.sourcePath,
                    to: runtime.destinationPath,
                    on: destination,
                    byteCount: sftpTransfer.byteCount,
                    overwrite: runtime.overwrite,
                    cancellation: runtime.cancellation,
                    progress: progress
                )
                result = .completed
            } catch SFTPError.cancelled {
                result = .cancelled
            } catch is CancellationError {
                result = .cancelled
            } catch {
                result = .failed(error.localizedDescription)
            }
            if ownsSource { await source.disconnect() }
            if ownsDestination { await destination?.disconnect() }
            finish(
                sftpTransfer.id, hostIDs: involvedHostIDs,
                borrowedIDs: borrowedIDs, state: result
            )
        }
        activeTasks[sftpTransfer.id] = task
    }

    private func hostIDs(for sftpTransfer: SFTPTransfer) -> [Host.ID] {
        if let runtime = remoteCopyRuntimes[sftpTransfer.id] {
            return Array(Set([runtime.sourceHostID, runtime.destinationHostID]))
        }
        return sftpTransfer.hostID.map { [$0] } ?? []
    }

    private func borrowedIDs(for sftpTransfer: SFTPTransfer) -> [UUID] {
        if let runtime = remoteCopyRuntimes[sftpTransfer.id] {
            return [
                runtime.sourceConnection.borrowedID,
                runtime.destinationConnection.borrowedID,
            ].compactMap { $0 }
        }
        return runtimes[sftpTransfer.id]?.connection.borrowedID.map { [$0] } ?? []
    }

    private func reserveBorrowedConnection(_ id: UUID) async throws {
        while activeBorrowedConnections.contains(id) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        activeBorrowedConnections.insert(id)
    }

    private func releaseBorrowedConnections(_ ids: [UUID]) {
        activeBorrowedConnections.subtract(ids)
        schedule()
    }

    private func finish(
        _ id: SFTPTransfer.ID, hostIDs: [Host.ID], borrowedIDs: [UUID] = [],
        state: SFTPTransfer.State
    ) {
        activeTasks.removeValue(forKey: id)
        for hostID in hostIDs {
            activePerHost[hostID] = max(0, activePerHost[hostID, default: 1] - 1)
        }
        releaseBorrowedConnections(borrowedIDs)
        let completion =
            runtimes.removeValue(forKey: id)?.completion
            ?? remoteCopyRuntimes.removeValue(forKey: id)?.completion
        store.finishSFTPTransfer(id, state: state)
        completion?(state)
    }
}
