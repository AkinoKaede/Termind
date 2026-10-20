// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

struct TerminalUploadConnection {
    let channel: any SFTPChannelProtocol
    let primaryRole: SFTPTransferPrimaryRole
}

enum TerminalUploadConnectionResolver {
    @MainActor
    static func resolve(
        isCurrent: () -> Bool,
        connectIndependent: () async throws -> any SFTPChannelProtocol,
        openPTYSFTPChannel: () async throws -> any SFTPChannelProtocol
    ) async throws -> TerminalUploadConnection {
        do {
            return TerminalUploadConnection(
                channel: try await connectIndependent(), primaryRole: .donatedConnection)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SFTPError {
            if case .cancelled = error { throw error }
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            return TerminalUploadConnection(
                channel: try await openPTYSFTPChannel(), primaryRole: .ptyConnectionFallback)
        } catch {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            return TerminalUploadConnection(
                channel: try await openPTYSFTPChannel(), primaryRole: .ptyConnectionFallback)
        }
    }
}

enum TerminalTransferRequest {
    case local([URL])
    case remote(SFTPRemoteItemsPayload, itemCount: Int)

    var itemCount: Int {
        switch self {
        case .local(let files): files.count
        case .remote(_, let itemCount): itemCount
        }
    }

    static func remote(
        data: Data,
        coordinator: SFTPTransferCoordinator
    ) -> TerminalTransferRequest? {
        guard let payload = try? JSONDecoder().decode(SFTPRemoteItemsPayload.self, from: data),
            let source = coordinator.remoteCopySource(for: payload),
            !source.files.isEmpty
        else { return nil }
        return .remote(payload, itemCount: source.files.count)
    }

    func prepare(
        on channel: SFTPChannelModel,
        coordinator: SFTPTransferCoordinator
    ) async {
        switch self {
        case .local(let files):
            await channel.prepareUpload(files)
        case .remote(let payload, _):
            await channel.prepareRemoteCopy(payload, coordinator: coordinator)
        }
    }
}

/// Pending terminal transfers belong to the SSH session, so rebuilding or moving its pane
/// does not replace preparation, conflict state, or the upload completion destination.
@Observable @MainActor
final class TerminalUploadModel {
    struct Target: Equatable {
        let generation: UUID?
        let destination: String
        var context: TerminalContextCoordinator.Ticket? = nil
    }

    private weak var session: SSHSessionModel?
    private var transfers: SFTPTransferCoordinator?
    private var pendingUploadChannel: SFTPChannelModel?
    private var pendingUploadItemCount = 0
    private var insertUploadedPaths = false
    private(set) var hasConflict = false
    private(set) var notice: WorkspaceUploadNotice?
    private var noticeTask: Task<Void, Never>?
    private var uploadPreparationTask: Task<Void, Never>?
    private var uploadPreparationID: UUID?
    private var uploadEnqueueTask: Task<Void, Never>?
    private var pendingContext: TerminalContextCoordinator.Ticket?

    init(session: SSHSessionModel) { self.session = session }

    var conflictCount: Int { pendingUploadChannel?.conflictCount ?? 0 }

    var uploadTargetProblem: String? {
        TerminalUploadAvailability.problem(
            isConnected: session?.status == .connected,
            hasTransferConfiguration: session?.transferSnapshot != nil,
            isWorkingDirectoryPending: session?.homeResolution.isPending ?? true,
            workingDirectory: session?.workingDirectory)
    }

    var target: Target? {
        guard uploadTargetProblem == nil, let session, let destination = session.workingDirectory else { return nil }
        return Target(
            generation: session.connectionAttemptID, destination: destination, context: session.directoryContextTicket)
    }

    @discardableResult
    func receiveFiles(
        _ urls: [URL], selectedTarget: Target? = nil,
        connections: RemoteConnectionCoordinator, transfers: SFTPTransferCoordinator
    ) -> Bool {
        if let selectedTarget, selectedTarget != target { return false }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        return prepare(
            .local(files), insertPaths: selectedTarget != nil, connections: connections, transfers: transfers)
    }

    @discardableResult
    func receiveRemoteDrop(
        _ data: Data, connections: RemoteConnectionCoordinator, transfers: SFTPTransferCoordinator
    ) -> Bool {
        guard let request = TerminalTransferRequest.remote(data: data, coordinator: transfers) else {
            showUploadNotice(.rejected(String(localized: AppStrings.SFTP.theCopiedSftpItemsAreInvalid)))
            return false
        }
        return prepare(request, insertPaths: false, connections: connections, transfers: transfers)
    }

    private func prepare(
        _ request: TerminalTransferRequest, insertPaths: Bool,
        connections: RemoteConnectionCoordinator, transfers: SFTPTransferCoordinator
    ) -> Bool {
        guard let sshSession = session else { return false }
        cancelPendingUpload()
        insertUploadedPaths = insertPaths
        guard uploadTargetProblem == nil,
            let snapshot = sshSession.transferSnapshot,
            let workingDirectory = sshSession.workingDirectory
        else {
            showUploadNotice(
                .rejected(
                    uploadTargetProblem
                        ?? String(localized: AppStrings.SFTP.theUploadDestinationIsUnavailable)
                )
            )
            return false
        }

        self.transfers = transfers
        let destination = RemotePath.normalized(workingDirectory)
        let generation = sshSession.connectionAttemptID
        let context = sshSession.directoryContextTicket
        pendingContext = context
        let preparationID = UUID()
        uploadPreparationID = preparationID
        pendingUploadItemCount = request.itemCount
        notice = .preparing(destination)

        uploadPreparationTask = Task {
            defer {
                if uploadPreparationID == preparationID {
                    uploadPreparationTask = nil
                    uploadPreparationID = nil
                }
            }
            var connectedChannel: (any SFTPChannelProtocol)?
            do {
                try await sshSession.confirmDirectoryContext(context)
                let resolved = try await TerminalUploadConnectionResolver.resolve(
                    isCurrent: { sshSession.connectionAttemptID == generation },
                    connectIndependent: {
                        let request = try sshSession.additionalConnectionRequest(from: snapshot)
                        return try await connections.connectSFTP(
                            using: request, progress: nil
                        )
                    },
                    openPTYSFTPChannel: {
                        try await sshSession.openPTYSFTPChannel(for: generation)
                    })
                let client = resolved.channel
                connectedChannel = client
                try Task.checkCancellation()
                guard sshSession.connectionAttemptID == generation else { throw CancellationError() }
                let uploadChannel = SFTPChannelModel(
                    hostID: sshSession.hostID,
                    initialPath: destination,
                    client: client,
                    additionalSnapshot: snapshot,
                    hostStore: sshSession.transferHostStore,
                    primaryRole: resolved.primaryRole,
                    homeResolution: sshSession.homeResolution
                )
                await request.prepare(on: uploadChannel, coordinator: transfers)
                try await sshSession.confirmDirectoryContext(context)
                try Task.checkCancellation()
                guard sshSession.connectionAttemptID == generation else { throw CancellationError() }
                if let error = uploadChannel.operationError {
                    uploadChannel.disconnect()
                    showUploadNotice(.rejected(error))
                    return
                }
                guard uploadChannel.hasPendingBatch else {
                    uploadChannel.disconnect()
                    showUploadNotice(.rejected(String(localized: AppStrings.SFTP.noUploadableFilesWereFound)))
                    return
                }
                pendingUploadChannel = uploadChannel
                connectedChannel = nil
                if uploadChannel.conflictCount > 0 {
                    notice = nil
                    hasConflict = true
                } else {
                    enqueue(.replace)
                }
            } catch is CancellationError {
                await connectedChannel?.disconnect()
                guard uploadPreparationID == preparationID else { return }
                notice = nil
            } catch {
                await connectedChannel?.disconnect()
                guard uploadPreparationID == preparationID,
                    sshSession.connectionAttemptID == generation
                else { return }
                showUploadNotice(.rejected(error.localizedDescription))
            }
        }
        return true
    }

    func enqueue(_ policy: TransferConflictPolicy) {
        guard let uploadChannel = pendingUploadChannel, let transfers, let sshSession = session else { return }
        let itemCount = pendingUploadItemCount
        let destination = uploadChannel.path
        let generation = sshSession.connectionAttemptID
        let insertPaths = insertUploadedPaths
        let context = pendingContext
        hasConflict = false
        uploadEnqueueTask = Task {
            do {
                try await sshSession.confirmDirectoryContext(context)
                try Task.checkCancellation()
            } catch {
                cancelPendingUpload()
                return
            }
            if uploadChannel.pendingRemoteCopyBatch != nil {
                await uploadChannel.enqueuePendingRemoteCopy(
                    policy: policy,
                    coordinator: transfers
                )
            } else {
                await uploadChannel.enqueuePending(
                    policy: policy,
                    coordinator: transfers,
                    uploadedPaths: insertPaths
                        ? { [weak session = sshSession] paths in
                            guard let session, session.status == .connected,
                                session.connectionAttemptID == generation, session.isDirectoryContextCurrent(context)
                            else { return }
                            session.insertUploadedPaths(paths)
                        } : nil
                )
            }
            let error = uploadChannel.operationError
            uploadChannel.disconnect()
            guard !Task.isCancelled, pendingUploadChannel === uploadChannel,
                sshSession.connectionAttemptID == generation
            else { return }
            uploadEnqueueTask = nil
            pendingUploadChannel = nil
            pendingUploadItemCount = 0
            self.transfers = nil
            if let error {
                showUploadNotice(.rejected(error))
            } else {
                showUploadNotice(.queued(itemCount, destination))
            }
        }
    }

    func cancelPendingUpload() {
        pendingContext = nil
        uploadPreparationTask?.cancel()
        uploadPreparationTask = nil
        uploadPreparationID = nil
        uploadEnqueueTask?.cancel()
        uploadEnqueueTask = nil
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
        hasConflict = false
        pendingUploadItemCount = 0
        transfers = nil
        guard let uploadChannel = pendingUploadChannel else { return }
        uploadChannel.cancelPendingBatch()
        uploadChannel.disconnect()
        pendingUploadChannel = nil
    }

    private func showUploadNotice(_ value: WorkspaceUploadNotice) {
        noticeTask?.cancel()
        notice = value
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(value.isRejected ? 3 : 2))
            guard !Task.isCancelled, notice == value else { return }
            notice = nil
            noticeTask = nil
        }
    }

}
