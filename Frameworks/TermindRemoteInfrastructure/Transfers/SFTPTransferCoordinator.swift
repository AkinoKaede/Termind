import Foundation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct SFTPRemoteItemsPayload: Codable, Hashable, Sendable {
    public var token: UUID
    public init(token: UUID) { self.token = token }
}

public nonisolated enum SFTPTransferConnection: Sendable {
    case saved(SSHAdditionalConnectionSnapshot)
    case context(SFTPTransferContext)
    case borrowed(id: UUID, channel: any SFTPChannelProtocol)

    public var managedContext: SFTPTransferContext? {
        if case .context(let context) = self { context } else { nil }
    }

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
        self.init(
            hostID: hostID,
            connection: .saved(SSHAdditionalConnectionSnapshot(configuration: configuration)),
            files: files
        )
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

    private typealias ChannelLease = SFTPChannelLease

    private let store: HostLibraryModel
    private let clientFactory: ClientFactory
    public let concurrencyScheduler: SFTPConcurrencyScheduler
    private var runtimes: [SFTPTransfer.ID: Runtime] = [:]
    private var remoteCopyRuntimes: [SFTPTransfer.ID: RemoteCopyRuntime] = [:]
    private var admissionTasks: [SFTPTransfer.ID: Task<Void, Never>] = [:]
    private var preferencesUpdateTask: Task<Void, Never>?
    private var activeTasks: [SFTPTransfer.ID: Task<Void, Never>] = [:]
    private var activePermits: [SFTPTransfer.ID: SFTPConcurrencyPermit] = [:]
    private var activeBorrowedConnections: Set<UUID> = []
    private var remoteCopySources: [UUID: (source: SFTPRemoteCopySource, createdAt: Date)] = [:]

    public private(set) var globalLimit: Int
    public private(set) var perHostLimit: Int
    public private(set) var strategy: SFTPConcurrencyStrategy

    public init(
        store: HostLibraryModel,
        clientFactory: @escaping ClientFactory,
        globalLimit: Int? = nil, perHostLimit: Int? = nil,
        strategy: SFTPConcurrencyStrategy? = nil,
        concurrencyScheduler: SFTPConcurrencyScheduler? = nil
    ) {
        self.store = store
        self.clientFactory = clientFactory
        let defaults = UserDefaults.standard
        let limits = SFTPPreferences(
            globalLimit: globalLimit ?? defaults.object(forKey: SettingsKey.sftpGlobalTransferLimit) as? Int
                ?? SFTPPreferences.defaultGlobalLimit,
            perHostLimit: perHostLimit ?? defaults.object(forKey: SettingsKey.sftpPerHostTransferLimit) as? Int
                ?? SFTPPreferences.defaultPerHostLimit,
            strategy: strategy ?? defaults.string(forKey: SettingsKey.sftpConcurrencyStrategy)
                .flatMap(SFTPConcurrencyStrategy.init(rawValue:)) ?? .smart)
        self.globalLimit = limits.globalLimit
        self.perHostLimit = limits.perHostLimit
        self.strategy = limits.strategy
        self.concurrencyScheduler = concurrencyScheduler ?? SFTPConcurrencyScheduler(preferences: limits)
    }

    public func updateLimits(global: Int, perHost: Int) {
        updatePreferences(
            SFTPPreferences(
                globalLimit: global, perHostLimit: perHost,
                strategy: strategy
            ))
    }

    public func updatePreferences(_ value: SFTPPreferences) {
        let limits = value.normalized
        globalLimit = limits.globalLimit
        perHostLimit = limits.perHostLimit
        strategy = limits.strategy
        let previous = preferencesUpdateTask
        preferencesUpdateTask = Task {
            await previous?.value
            await concurrencyScheduler.updatePreferences(limits)
        }
        schedule()
    }

    public var sftpTransfers: [SFTPTransfer] {
        store.sftpTransfers.sorted { $0.queuedAt < $1.queuedAt }
    }
    public var activeCount: Int { activeTasks.count }
    public var summary: SFTPTransferSummary {
        let active = sftpTransfers.filter { $0.state.isActive }
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
        let reservation = UUID()
        retain(source.connection, for: reservation)
        let borrowedID = source.connection.borrowedID
        if let borrowedID {
            try await reserveBorrowedConnection(borrowedID)
        }
        defer {
            if let borrowedID { releaseBorrowedConnections([borrowedID]) }
        }
        var lease: ChannelLease?
        do {
            let acquired = try await clientLease(for: source.connection)
            lease = acquired
            let client = acquired.channel
            let entries = try await SFTPRemoteCopyPlanner.manifest(files: source.files, client: client)
            await lease?.disconnect()
            await source.connection.managedContext?.releaseTransfer(reservation)
            return (source, entries)
        } catch {
            await lease?.disconnect()
            await source.connection.managedContext?.releaseTransfer(reservation)
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
        retain(connection, for: sftpTransfer.id)
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
            connection: .saved(SSHAdditionalConnectionSnapshot(configuration: configuration)), scopedRoot: scopedRoot,
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
        retain(sourceConnection, for: sftpTransfer.id)
        retain(destinationConnection, for: sftpTransfer.id)
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
            sourceConnection: .saved(SSHAdditionalConnectionSnapshot(configuration: sourceConfiguration)),
            destinationPath: destinationPath, destinationHostID: destinationHostID,
            destinationConnection: .saved(SSHAdditionalConnectionSnapshot(configuration: destinationConfiguration)),
            byteCount: byteCount, overwrite: overwrite, completion: completion
        )
    }

    public func replaceBorrowedChannel(_ connectionID: UUID, with channel: any SFTPChannelProtocol) {
        for id in Array(runtimes.keys) where runtimes[id]?.connection.borrowedID == connectionID {
            runtimes[id]?.connection = .borrowed(id: connectionID, channel: channel)
        }
    }

    public func canPause(_ id: SFTPTransfer.ID) -> Bool {
        guard let transfer = store.sftpTransfer(id) else { return false }
        return runtimes[id] != nil && transfer.state.isActive
    }

    public func pause(_ id: SFTPTransfer.ID) {
        guard canPause(id), let runtime = runtimes[id] else { return }
        runtimes[id]?.pauseRequested = true
        if activeTasks[id] == nil {
            admissionTasks.removeValue(forKey: id)?.cancel()
            store.setSFTPTransferState(.paused, for: id)
            runtime.connection.managedContext?.suspendTransfer(id)
        } else {
            runtime.cancellation.cancel()
        }
    }

    public func resume(_ id: SFTPTransfer.ID) {
        guard store.sftpTransfer(id)?.state == .paused, activeTasks[id] == nil, runtimes[id] != nil else { return }
        runtimes[id]?.pauseRequested = false
        runtimes[id]?.cancellation = TransferCancellationToken()
        runtimes[id]?.generation = UUID()
        if let connection = runtimes[id]?.connection { retain(connection, for: id) }
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
                admissionTasks.removeValue(forKey: id)?.cancel()
                let task = Task { [self] in
                    var state: SFTPTransfer.State = .cancelled
                    do { try await cleanup(runtime, direction: transfer.direction, channel: nil) } catch {
                        state = .failed(error.localizedDescription)
                    }
                    await runtime.connection.managedContext?.releaseTransfer(id)
                    activeTasks[id] = nil
                    let completion = runtimes.removeValue(forKey: id)?.completion
                    store.finishSFTPTransfer(id, state: state)
                    completion?(state)
                    schedule()
                }
                activeTasks[id] = task
            }
        } else if transfer.state == .queued, activeTasks[id] == nil {
            admissionTasks.removeValue(forKey: id)?.cancel()
            let contexts = managedContexts(for: id)
            guard let runtime = remoteCopyRuntimes.removeValue(forKey: id) else { return }
            activeTasks[id] = Task { [self] in
                for context in contexts { await context.releaseTransfer(id) }
                activeTasks[id] = nil
                store.finishSFTPTransfer(id, state: .cancelled)
                runtime.completion?(.cancelled)
                schedule()
            }
        } else {
            remoteCopyRuntimes[id]?.cancellation.cancel()
        }
    }

    private func cleanup(
        _ runtime: Runtime, direction: SFTPTransfer.Direction, channel: (any SFTPChannelProtocol)?
    ) async throws {
        let checkpoint = runtime.resume.snapshot
        guard !checkpoint.committed, let path = checkpoint.temporaryPath else { return }
        if direction == .download {
            let scoped = runtime.scopedRoot.startAccessingSecurityScopedResource()
            defer { if scoped { runtime.scopedRoot.stopAccessingSecurityScopedResource() } }
            do {
                if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            } catch { throw SFTPTemporaryFileCleanupError(path: path, cause: error) }
        } else if let channel {
            try await runtime.resume.cleanup(using: channel)
        } else {
            do {
                if let id = runtime.connection.borrowedID { try await reserveBorrowedConnection(id) }
                defer { if let id = runtime.connection.borrowedID { releaseBorrowedConnections([id]) } }
                let lease = try await clientLease(for: runtime.connection)
                do { try await runtime.resume.cleanup(using: lease.channel) } catch {
                    await lease.disconnect()
                    throw error
                }
                await lease.disconnect()
            } catch { throw SFTPTemporaryFileCleanupError(path: path, cause: error) }
        }
    }

    public func pauseAll() {
        for transfer in sftpTransfers where transfer.state.isActive {
            if canPause(transfer.id) { pause(transfer.id) } else { cancel(transfer.id) }
        }
    }

    public func waitForCancellation() async {
        while !activeTasks.isEmpty || !admissionTasks.isEmpty {
            let tasks = Array(activeTasks.values) + Array(admissionTasks.values)
            for task in tasks { await task.value }
        }
    }

    public func cancelAll() {
        let ids = store.sftpTransfers.filter { !$0.state.isFinished }.map(\.id)
        for id in ids { cancel(id) }
    }

    public func cancelAll(for hostID: Host.ID) {
        for transfer in store.sftpTransfers where transfer.involves(hostID) {
            cancel(transfer.id)
        }
    }

    public func cancelTransfers(usingBorrowedConnection connectionID: UUID) async {
        let ids = store.sftpTransfers.compactMap { transfer -> SFTPTransfer.ID? in
            guard !transfer.state.isFinished,
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

    public func removeFinished(_ id: SFTPTransfer.ID) { store.removeFinishedSFTPTransfer(id) }

    private func schedule() {
        for sftpTransfer in store.sftpTransfers where sftpTransfer.state == .queued {
            guard activeTasks[sftpTransfer.id] == nil, admissionTasks[sftpTransfer.id] == nil,
                runtimes[sftpTransfer.id]?.cancelRequested != true,
                runtimes[sftpTransfer.id] != nil || remoteCopyRuntimes[sftpTransfer.id] != nil
            else { continue }
            let hostIDs = Set(hostIDs(for: sftpTransfer))
            guard let anchorHostID = anchorHostID(for: sftpTransfer), !hostIDs.isEmpty else { continue }
            let source = workSource(for: sftpTransfer)
            let exclusiveResourceIDs = Set(borrowedIDs(for: sftpTransfer))
            let scheduler = concurrencyScheduler
            let preferencesUpdateTask = preferencesUpdateTask
            admissionTasks[sftpTransfer.id] = Task { @MainActor [weak self] in
                do {
                    await preferencesUpdateTask?.value
                    let permit = try await scheduler.acquire(
                        anchorHostID: anchorHostID,
                        hostIDs: hostIDs,
                        source: source,
                        byteCount: sftpTransfer.byteCount >= 0 ? sftpTransfer.byteCount : nil,
                        exclusiveResourceIDs: exclusiveResourceIDs
                    )
                    guard let self else {
                        await permit.release()
                        return
                    }
                    admissionTasks[sftpTransfer.id] = nil
                    guard store.sftpTransfer(sftpTransfer.id)?.state == .queued,
                        runtimes[sftpTransfer.id]?.cancelRequested != true,
                        runtimes[sftpTransfer.id] != nil || remoteCopyRuntimes[sftpTransfer.id] != nil
                    else {
                        await permit.release()
                        return
                    }
                    activePermits[sftpTransfer.id] = permit
                    start(sftpTransfer, mode: permit.schedulingMode)
                } catch {
                    self?.admissionTasks[sftpTransfer.id] = nil
                }
            }
        }
    }

    private func start(_ sftpTransfer: SFTPTransfer, mode: SSHChannelSchedulingMode) {
        for context in managedContexts(for: sftpTransfer.id) { context.reserveSlot() }
        if let runtime = remoteCopyRuntimes[sftpTransfer.id] {
            startRemoteCopy(sftpTransfer, runtime: runtime, mode: mode)
            return
        }
        guard let hostID = sftpTransfer.hostID, let runtime = runtimes[sftpTransfer.id] else { return }
        store.setSFTPTransferState(.running, for: sftpTransfer.id)
        let borrowedIDs = Array(runtime.connection.borrowedID.map { [$0] } ?? [])
        activeBorrowedConnections.formUnion(borrowedIDs)
        let task = Task { [weak self] in
            guard let self else { return }
            let scoped = runtime.scopedRoot.startAccessingSecurityScopedResource()
            defer { if scoped { runtime.scopedRoot.stopAccessingSecurityScopedResource() } }
            var lease: ChannelLease?
            var result: SFTPTransfer.State
            do {
                let acquired = try await clientLease(
                    for: runtime.connection, mode: mode, cancellation: runtime.cancellation)
                lease = acquired
                let client = acquired.channel
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
                do { try await cleanup(runtime, direction: sftpTransfer.direction, channel: lease?.channel) } catch {
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
            await finish(
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

    private func startRemoteCopy(
        _ sftpTransfer: SFTPTransfer,
        runtime: RemoteCopyRuntime,
        mode: SSHChannelSchedulingMode
    ) {
        let involvedHostIDs = Array(Set([runtime.sourceHostID, runtime.destinationHostID]))
        store.setSFTPTransferState(.running, for: sftpTransfer.id)
        let borrowedIDs = [
            runtime.sourceConnection.borrowedID,
            runtime.destinationConnection.borrowedID,
        ].compactMap { $0 }
        activeBorrowedConnections.formUnion(borrowedIDs)
        let task = Task { [weak self] in
            guard let self else { return }
            var sourceLease: ChannelLease?
            var destinationLease: ChannelLease?
            let result: SFTPTransfer.State
            do {
                let sourceID = runtime.sourceConnection.managedContext?.id
                let destinationID = runtime.destinationConnection.managedContext?.id
                if let sourceID, sourceID == destinationID {
                    sourceLease = try await clientLease(
                        for: runtime.sourceConnection, mode: mode, cancellation: runtime.cancellation)
                    destinationLease = sourceLease
                } else if let sourceID, let destinationID, sourceID.uuidString > destinationID.uuidString {
                    destinationLease = try await clientLease(
                        for: runtime.destinationConnection, mode: mode, cancellation: runtime.cancellation)
                    sourceLease = try await clientLease(
                        for: runtime.sourceConnection, mode: mode, cancellation: runtime.cancellation)
                } else {
                    sourceLease = try await clientLease(
                        for: runtime.sourceConnection, mode: mode, cancellation: runtime.cancellation)
                    destinationLease = try await clientLease(
                        for: runtime.destinationConnection, mode: mode, cancellation: runtime.cancellation)
                }
                guard let acquiredSource = sourceLease, let acquiredDestination = destinationLease else {
                    throw SFTPError.notConnected
                }
                let progress: @Sendable (SFTPProgress) -> Void = { [weak self] value in
                    Task { @MainActor in
                        self?.store.updateSFTPTransfer(
                            sftpTransfer.id, completedBytes: value.completedBytes,
                            totalBytes: value.totalBytes,
                            bytesPerSecond: value.bytesPerSecond
                        )
                    }
                }
                try await acquiredSource.channel.copyFile(
                    from: runtime.sourcePath,
                    to: runtime.destinationPath,
                    on: acquiredDestination.channel,
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
            await finish(
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

    private func anchorHostID(for sftpTransfer: SFTPTransfer) -> Host.ID? {
        sftpTransfer.destinationHostID ?? sftpTransfer.sourceHostID ?? sftpTransfer.hostID
    }

    private func workSource(for sftpTransfer: SFTPTransfer) -> SFTPWorkSource {
        if let runtime = remoteCopyRuntimes[sftpTransfer.id],
            let context = runtime.destinationConnection.managedContext
        {
            return .workspace(context.id)
        }
        if let context = runtimes[sftpTransfer.id]?.connection.managedContext {
            return .workspace(context.id)
        }
        return .batch(sftpTransfer.batchID)
    }

    private func clientLease(
        for connection: SFTPTransferConnection,
        mode: SSHChannelSchedulingMode = .channelsOnly,
        cancellation: TransferCancellationToken? = nil
    ) async throws -> ChannelLease {
        switch connection {
        case .context(let context):
            return try await context.acquire(mode: mode, cancellation: cancellation)
        case .saved(let snapshot):
            let client = clientFactory()
            do {
                let request = try store.additionalConnectionRequest(from: snapshot)
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
            return ChannelLease(channel: client) { await client.disconnect() }
        case .borrowed(_, let channel):
            return ChannelLease(channel: channel) {}
        }
    }

    private func retain(_ connection: SFTPTransferConnection, for id: UUID) {
        guard let context = connection.managedContext else { return }
        context.configureClientFactory(clientFactory)
        context.retainTransfer(id)
        context.availabilityChanged = { [weak self] in self?.schedule() }
    }

    private func managedContexts(for id: UUID) -> [SFTPTransferContext] {
        var connections: [SFTPTransferConnection] = []
        if let runtime = runtimes[id] { connections.append(runtime.connection) }
        if let runtime = remoteCopyRuntimes[id] {
            connections += [runtime.sourceConnection, runtime.destinationConnection]
        }
        var seen: Set<UUID> = []
        return connections.compactMap(\.managedContext).filter { seen.insert($0.id).inserted }
            .sorted { $0.id.uuidString < $1.id.uuidString }
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
    ) async {
        for context in managedContexts(for: id) {
            context.releaseSlot()
            await context.releaseTransfer(id)
        }
        if state == .paused {
            store.setSFTPTransferState(.paused, for: id)
        } else {
            let completion =
                runtimes.removeValue(forKey: id)?.completion
                ?? remoteCopyRuntimes.removeValue(forKey: id)?.completion
            store.finishSFTPTransfer(id, state: state)
            completion?(state)
        }
        activeTasks.removeValue(forKey: id)
        let permit = activePermits.removeValue(forKey: id)
        releaseBorrowedConnections(borrowedIDs)
        await permit?.release()
        schedule()
    }
}
