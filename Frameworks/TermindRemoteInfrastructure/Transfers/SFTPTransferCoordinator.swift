import Foundation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct SFTPRemoteItemsPayload: Codable, Hashable, Sendable {
    public var token: UUID
    public init(token: UUID) { self.token = token }
}

public nonisolated enum SFTPTransferConnection: Sendable {
    case saved(SSHConnectionConfiguration)
    case borrowed(id: UUID, client: any SFTPClientProtocol)

    public var borrowedID: UUID? {
        if case .borrowed(let id, _) = self { id } else { nil }
    }
}

public nonisolated struct SFTPRemoteCopySource: Sendable {
    public var hostID: Host.ID
    public var connection: SFTPTransferConnection
    public var files: [RemoteFile]
    public var homeDirectory: String?

    public init(
        hostID: Host.ID, connection: SFTPTransferConnection, files: [RemoteFile],
        homeDirectory: String? = nil
    ) {
        self.hostID = hostID
        self.connection = connection
        self.files = files
        self.homeDirectory = homeDirectory
    }

    public init(hostID: Host.ID, configuration: SSHConnectionConfiguration, files: [RemoteFile]) {
        self.init(hostID: hostID, connection: .saved(configuration), files: files)
    }
}

public nonisolated struct SFTPRemoteManifestEntry: Sendable {
    public var sourcePath: String
    public var relativePath: String
    public var kind: RemoteFile.Kind
    public var byteCount: Int64

    public var isDirectory: Bool { kind == .directory }
}

public nonisolated enum TransferConflictPolicy: String, CaseIterable, Identifiable, Sendable {
    case replace, skip, keepBoth
    public var id: String { rawValue }
}

public nonisolated struct SFTPTransferSummary: Equatable, Sendable {
    public var activeCount: Int
    public var failedCount: Int
    public var aggregateProgress: Double?
}

@MainActor
public final class SFTPEditTransferReceipt {
    public internal(set) var version: SFTPFileVersion?
    public init() {}
}

@Observable
public final class SFTPTransferCoordinator {
    public typealias ClientFactory = @Sendable () -> any SFTPClientProtocol

    private struct Runtime {
        var connection: SFTPTransferConnection
        var localURL: URL
        var remotePath: String
        var overwrite: Bool
        var scopedRoot: URL
        var cancellation: TransferCancellationToken
        var completion: ((SFTPTransfer.State) -> Void)?
        var resume = SFTPResumeState()
        var editReceipt: SFTPEditTransferReceipt?
        var pauseRequested = false
        var cancelRequested = false
        var generation = UUID()
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

    private struct ClientLease {
        let client: any SFTPClientProtocol
        let isOwned: Bool

        func disconnect() async {
            if isOwned { await client.disconnect() }
        }
    }

    private let store: HostLibraryModel
    private let clientFactory: ClientFactory
    private var runtimes: [SFTPTransfer.ID: Runtime] = [:]
    private var remoteCopyRuntimes: [SFTPTransfer.ID: RemoteCopyRuntime] = [:]
    private var activeTasks: [SFTPTransfer.ID: Task<Void, Never>] = [:]
    private var activePerHost: [Host.ID: Int] = [:]
    private var activeBorrowedConnections: Set<UUID> = []
    private var remoteCopySources: [UUID: (source: SFTPRemoteCopySource, createdAt: Date)] = [:]

    public private(set) var globalLimit: Int
    public private(set) var perHostLimit: Int

    public init(
        store: HostLibraryModel,
        clientFactory: @escaping ClientFactory,
        globalLimit: Int? = nil, perHostLimit: Int? = nil
    ) {
        self.store = store
        self.clientFactory = clientFactory
        let defaults = UserDefaults.standard
        let normalizedGlobal = Self.normalizedLimit(
            globalLimit ?? defaults.object(forKey: SettingsKey.sftpGlobalTransferLimit) as? Int
                ?? SettingsKey.defaultSFTPGlobalTransferLimit
        )
        self.globalLimit = normalizedGlobal
        self.perHostLimit = min(
            Self.normalizedLimit(
                perHostLimit ?? defaults.object(forKey: SettingsKey.sftpPerHostTransferLimit) as? Int
                    ?? SettingsKey.defaultSFTPPerHostTransferLimit
            ),
            normalizedGlobal
        )
    }

    public func updateLimits(global: Int, perHost: Int) {
        globalLimit = Self.normalizedLimit(global)
        perHostLimit = min(Self.normalizedLimit(perHost), globalLimit)
        schedule()
    }

    private static func normalizedLimit(_ value: Int) -> Int {
        min(
            max(value, SettingsKey.sftpTransferLimitRange.lowerBound),
            SettingsKey.sftpTransferLimitRange.upperBound
        )
    }

    public var sftpTransfers: [SFTPTransfer] {
        store.sftpTransfers.sorted { $0.queuedAt < $1.queuedAt }
    }
    public var activeCount: Int { activeTasks.count }
    public var summary: SFTPTransferSummary {
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

    public func registerRemoteCopySource(_ source: SFTPRemoteCopySource) -> SFTPRemoteItemsPayload {
        let expiration = Date().addingTimeInterval(-60 * 60)
        remoteCopySources = remoteCopySources.filter { $0.value.createdAt > expiration }
        let payload = SFTPRemoteItemsPayload(token: UUID())
        remoteCopySources[payload.token] = (source, Date())
        return payload
    }

    public func remoteCopySource(for payload: SFTPRemoteItemsPayload) -> SFTPRemoteCopySource? {
        remoteCopySources[payload.token]?.source
    }

    public func remoteManifest(for payload: SFTPRemoteItemsPayload) async throws
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
        let lease = try await clientLease(for: source.connection)
        let client = lease.client
        do {
            let entries = try await SFTPRemoteCopyPlanner.manifest(files: source.files, client: client)
            await lease.disconnect()
            return (source, entries)
        } catch {
            await lease.disconnect()
            throw error
        }
    }

    @discardableResult
    public func enqueue(
        direction: SFTPTransfer.Direction, batchID: UUID,
        localURL: URL, remotePath: String, byteCount: Int64,
        hostID: Host.ID, connection: SFTPTransferConnection,
        scopedRoot: URL, overwrite: Bool,
        homeDirectory: String? = nil,
        editPolicy: SFTPEditUploadPolicy? = nil,
        editReceipt: SFTPEditTransferReceipt? = nil,
        completion: ((SFTPTransfer.State) -> Void)? = nil
    ) -> SFTPTransfer.ID {
        let sftpTransfer = SFTPTransfer(
            batchID: batchID, hostID: hostID,
            sourceHostID: direction == .download ? hostID : nil,
            destinationHostID: direction == .upload ? hostID : nil,
            direction: direction,
            localPath: localURL.path, remotePath: remotePath,
            sourceHomeDirectory: direction == .download ? homeDirectory : nil,
            destinationHomeDirectory: direction == .upload ? homeDirectory : nil,
            byteCount: byteCount, queuedAt: Date()
        )
        store.enqueueSFTPTransfer(sftpTransfer)
        runtimes[sftpTransfer.id] = Runtime(
            connection: connection, localURL: localURL,
            remotePath: remotePath, overwrite: overwrite,
            scopedRoot: scopedRoot, cancellation: TransferCancellationToken(),
            completion: completion,
            resume: SFTPResumeState(editPolicy: editPolicy, capturesFileVersion: editReceipt != nil),
            editReceipt: editReceipt
        )
        schedule()
        return sftpTransfer.id
    }

    public func enqueue(
        direction: SFTPTransfer.Direction, batchID: UUID,
        localURL: URL, remotePath: String, byteCount: Int64,
        hostID: Host.ID, configuration: SSHConnectionConfiguration,
        scopedRoot: URL, overwrite: Bool,
        homeDirectory: String? = nil,
        completion: ((SFTPTransfer.State) -> Void)? = nil
    ) {
        enqueue(
            direction: direction, batchID: batchID, localURL: localURL,
            remotePath: remotePath, byteCount: byteCount, hostID: hostID,
            connection: .saved(configuration), scopedRoot: scopedRoot,
            overwrite: overwrite, homeDirectory: homeDirectory, completion: completion
        )
    }

    public func enqueueRemoteCopy(
        batchID: UUID,
        sourcePath: String, sourceHostID: Host.ID,
        sourceConnection: SFTPTransferConnection,
        destinationPath: String, destinationHostID: Host.ID,
        destinationConnection: SFTPTransferConnection,
        byteCount: Int64, overwrite: Bool,
        sourceHomeDirectory: String? = nil,
        destinationHomeDirectory: String? = nil,
        completion: ((SFTPTransfer.State) -> Void)? = nil
    ) {
        let sftpTransfer = SFTPTransfer(
            batchID: batchID, hostID: destinationHostID,
            sourceHostID: sourceHostID, destinationHostID: destinationHostID,
            direction: .copy,
            localPath: sourcePath, remotePath: destinationPath,
            sourceHomeDirectory: sourceHomeDirectory,
            destinationHomeDirectory: destinationHomeDirectory,
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

    public func enqueueRemoteCopy(
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

    public func replaceBorrowedConnection(_ connectionID: UUID, with client: any SFTPClientProtocol) {
        for id in Array(runtimes.keys) where runtimes[id]?.connection.borrowedID == connectionID {
            runtimes[id]?.connection = .borrowed(id: connectionID, client: client)
        }
    }

    public func canPause(_ id: SFTPTransfer.ID) -> Bool {
        guard let transfer = store.sftpTransfer(id) else { return false }
        return runtimes[id] != nil && (transfer.state == .queued || transfer.state == .running)
    }

    public func pause(_ id: SFTPTransfer.ID) {
        guard canPause(id), let runtime = runtimes[id] else { return }
        runtimes[id]?.pauseRequested = true
        if activeTasks[id] == nil {
            store.setSFTPTransferState(.paused, for: id)
        } else {
            runtime.cancellation.cancel()
        }
    }

    public func resume(_ id: SFTPTransfer.ID) {
        guard store.sftpTransfer(id)?.state == .paused, activeTasks[id] == nil, runtimes[id] != nil else { return }
        runtimes[id]?.pauseRequested = false
        runtimes[id]?.cancellation = TransferCancellationToken()
        runtimes[id]?.generation = UUID()
        store.setSFTPTransferState(.queued, for: id)
        schedule()
    }

    public func cancel(_ id: SFTPTransfer.ID) {
        guard let transfer = store.sftpTransfer(id) else { return }
        if let runtime = runtimes[id] {
            guard !runtime.cancelRequested else { return }
            runtimes[id]?.cancelRequested = true
            runtimes[id]?.pauseRequested = false
            runtime.cancellation.cancel()
            if activeTasks[id] == nil {
                let task = Task { [self] in
                    var state: SFTPTransfer.State = .cancelled
                    do { try await cleanup(runtime, direction: transfer.direction, client: nil) } catch {
                        state = .failed(error.localizedDescription)
                    }
                    activeTasks[id] = nil
                    let completion = runtimes.removeValue(forKey: id)?.completion
                    store.finishSFTPTransfer(id, state: state)
                    completion?(state)
                    schedule()
                }
                activeTasks[id] = task
            }
        } else if transfer.state == .queued {
            let completion = remoteCopyRuntimes.removeValue(forKey: id)?.completion
            store.finishSFTPTransfer(id, state: .cancelled)
            completion?(.cancelled)
        } else {
            remoteCopyRuntimes[id]?.cancellation.cancel()
        }
    }

    private func cleanup(
        _ runtime: Runtime, direction: SFTPTransfer.Direction, client: (any SFTPClientProtocol)?
    ) async throws {
        let checkpoint = runtime.resume.snapshot
        guard !checkpoint.committed, let path = checkpoint.temporaryPath else { return }
        if direction == .download {
            let scoped = runtime.scopedRoot.startAccessingSecurityScopedResource()
            defer { if scoped { runtime.scopedRoot.stopAccessingSecurityScopedResource() } }
            do {
                if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            } catch { throw SFTPTemporaryFileCleanupError(path: path, cause: error) }
        } else if let client {
            try await runtime.resume.cleanup(using: client)
        } else {
            do {
                if let id = runtime.connection.borrowedID { try await reserveBorrowedConnection(id) }
                defer { if let id = runtime.connection.borrowedID { releaseBorrowedConnections([id]) } }
                let lease = try await clientLease(for: runtime.connection, allowsAuthentication: false)
                do { try await runtime.resume.cleanup(using: lease.client) } catch {
                    await lease.disconnect()
                    throw error
                }
                await lease.disconnect()
            } catch { throw SFTPTemporaryFileCleanupError(path: path, cause: error) }
        }
    }

    public func pauseAll() {
        for transfer in sftpTransfers where transfer.state == .queued || transfer.state == .running {
            if canPause(transfer.id) { pause(transfer.id) } else { cancel(transfer.id) }
        }
    }

    public func waitForCancellation() async {
        while !activeTasks.isEmpty {
            let tasks = Array(activeTasks.values)
            for task in tasks { await task.value }
        }
    }

    public func cancelAll() {
        let ids = store.sftpTransfers.compactMap { sftpTransfer -> SFTPTransfer.ID? in
            switch sftpTransfer.state {
            case .queued, .running, .paused: sftpTransfer.id
            case .completed, .failed, .cancelled: nil
            }
        }
        for id in ids { cancel(id) }
    }

    public func cancelAll(for hostID: Host.ID) {
        for transfer in store.sftpTransfers where transfer.involves(hostID) {
            cancel(transfer.id)
        }
    }

    public func cancelTransfers(usingBorrowedConnection connectionID: UUID) async {
        let ids = store.sftpTransfers.compactMap { transfer -> SFTPTransfer.ID? in
            guard transfer.state == .queued || transfer.state == .running || transfer.state == .paused,
                borrowedIDs(for: transfer).contains(connectionID)
            else { return nil }
            return transfer.id
        }
        for id in ids { cancel(id) }
        let tasks = ids.compactMap { activeTasks[$0] }
        for task in tasks { await task.value }
        while activeBorrowedConnections.contains(connectionID) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    public func clearFinished() { store.clearFinishedSFTPTransfers() }

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
            var lease: ClientLease?
            var result: SFTPTransfer.State
            do {
                let acquired = try await clientLease(for: runtime.connection, cancellation: runtime.cancellation)
                lease = acquired
                let client = acquired.client
                let progress: @Sendable (SFTPProgress) -> Void = { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.runtimes[sftpTransfer.id]?.generation == runtime.generation,
                            self.store.sftpTransfer(sftpTransfer.id)?.state == .running
                        else { return }
                        self.store.updateSFTPTransfer(
                            sftpTransfer.id, completedBytes: value.completedBytes,
                            totalBytes: value.totalBytes, bytesPerSecond: value.bytesPerSecond
                        )
                    }
                }
                switch sftpTransfer.direction {
                case .upload:
                    try await client.uploadFile(
                        from: runtime.localURL, to: runtime.remotePath,
                        overwrite: runtime.overwrite, cancellation: runtime.cancellation, resume: runtime.resume,
                        progress: progress
                    )
                case .download:
                    try FileManager.default.createDirectory(
                        at: runtime.localURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try await client.downloadFile(
                        from: runtime.remotePath, to: runtime.localURL,
                        overwrite: runtime.overwrite, cancellation: runtime.cancellation, resume: runtime.resume,
                        progress: progress
                    )
                case .copy:
                    throw SFTPError.operation("Invalid copy transfer runtime.")
                }
                result = .completed
                runtime.editReceipt?.version = runtime.resume.snapshot.committedVersion
            } catch {
                let current = runtimes[sftpTransfer.id]
                if current?.cancelRequested == true {
                    result = .cancelled
                } else if !(error is SFTPResumeFailure)
                    && (current?.pauseRequested == true || Self.isRecoverable(error))
                {
                    result = .paused
                } else {
                    result = .failed(error.localizedDescription)
                }
            }
            if result != .paused && result != .completed {
                do { try await cleanup(runtime, direction: sftpTransfer.direction, client: lease?.client) } catch {
                    result = .failed(error.localizedDescription)
                }
            }
            if result == .paused || result == .completed {
                let snapshot = runtime.resume.snapshot
                store.updateSFTPTransfer(
                    sftpTransfer.id, completedBytes: snapshot.offset,
                    totalBytes: snapshot.source?.byteCount ?? sftpTransfer.byteCount, bytesPerSecond: 0)
            }
            await lease?.disconnect()
            finish(
                sftpTransfer.id, hostIDs: [hostID], borrowedIDs: borrowedIDs,
                state: result
            )
        }
        activeTasks[sftpTransfer.id] = task
    }

    private static func isRecoverable(_ error: any Error) -> Bool {
        switch error {
        case SFTPError.notConnected, SFTPError.connectionLost: true
        default: false
        }
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
            var sourceLease: ClientLease?
            var destinationLease: ClientLease?
            let result: SFTPTransfer.State
            do {
                let acquiredSource = try await clientLease(
                    for: runtime.sourceConnection, cancellation: runtime.cancellation)
                sourceLease = acquiredSource
                let acquiredDestination = try await clientLease(
                    for: runtime.destinationConnection, cancellation: runtime.cancellation
                )
                destinationLease = acquiredDestination
                let progress: @Sendable (SFTPProgress) -> Void = { [weak self] value in
                    Task { @MainActor in
                        self?.store.updateSFTPTransfer(
                            sftpTransfer.id, completedBytes: value.completedBytes,
                            totalBytes: value.totalBytes,
                            bytesPerSecond: value.bytesPerSecond
                        )
                    }
                }
                try await acquiredSource.client.copyFile(
                    from: runtime.sourcePath,
                    to: runtime.destinationPath,
                    on: acquiredDestination.client,
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
            await sourceLease?.disconnect()
            await destinationLease?.disconnect()
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

    private func clientLease(
        for connection: SFTPTransferConnection, cancellation: TransferCancellationToken? = nil,
        allowsAuthentication: Bool = true
    ) async throws -> ClientLease {
        switch connection {
        case .saved(let configuration):
            let client = clientFactory()
            do {
                var request = SSHConnectionRequest(configuration: configuration)
                if !allowsAuthentication {
                    // Cleanup after cancellation must not start another user interaction.
                    // If fresh MFA is required, retain the existing cleanup-failure report.
                    request.keyboardInteractive = { _ in throw CancellationError() }
                }
                let openingRequest = request
                let opening = Task {
                    try await client.connect(using: openingRequest, progress: nil, connectionFailure: nil)
                }
                let observer = cancellation?.observeCancellation { opening.cancel() }
                defer { if let observer { cancellation?.removeObserver(observer) } }
                try await withTaskCancellationHandler {
                    try await opening.value
                    try Task.checkCancellation()
                    if cancellation?.isCancelled == true { throw CancellationError() }
                } onCancel: {
                    opening.cancel()
                }
            } catch {
                await client.disconnect()
                throw error
            }
            return ClientLease(client: client, isOwned: true)
        case .borrowed(_, let client):
            return ClientLease(client: client, isOwned: false)
        }
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
        if state == .paused {
            store.setSFTPTransferState(.paused, for: id)
            schedule()
            return
        }
        let completion =
            runtimes.removeValue(forKey: id)?.completion
            ?? remoteCopyRuntimes.removeValue(forKey: id)?.completion
        store.finishSFTPTransfer(id, state: state)
        completion?(state)
    }
}
