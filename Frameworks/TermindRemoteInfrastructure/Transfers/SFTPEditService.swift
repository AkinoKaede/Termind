// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

@MainActor
public final class SFTPEditService {
    private struct Key: Hashable {
        let hostID: Host.ID
        let path: String
    }
    private struct Confirmation {
        let version: SFTPFileVersion?
    }
    /// Retain route identity, never credentials, alongside an editable copy.
    private struct Destination: Equatable {
        struct Hop: Equatable {
            let host: String
            let port: Int
            let username: String
            let keys: Set<SSHHostKeyIdentity>
            let proxy: [String]
        }
        let hops: [Hop]

        init(_ snapshot: SSHAdditionalConnectionSnapshot) {
            func proxy(_ value: SSHAdditionalConnectionSnapshot.Proxy?) -> [String] {
                guard let value else { return [] }
                return [value.kind.rawValue, value.hostname, String(value.port)]
            }
            hops =
                snapshot.jumps.map {
                    Hop(
                        host: $0.host, port: $0.port, username: $0.authentication.username,
                        keys: $0.expectedHostKeys,
                        proxy: proxy($0.proxy))
                } + [
                    Hop(
                        host: snapshot.target.host, port: snapshot.target.port,
                        username: snapshot.target.authentication.username,
                        keys: snapshot.target.expectedHostKeys, proxy: proxy(snapshot.target.proxy))
                ]
        }
    }

    public let model = SFTPEditModel()
    private let transfers: SFTPTransferCoordinator
    private let localFiles = SFTPEditLocalFiles()
    private let host: ((Host.ID) -> Host?)?
    private var originalHosts: [Host.ID: Host] = [:]
    private var destinations: [UUID: Destination] = [:]
    private var opening: [Key: Task<URL, any Error>] = [:]
    private var generations: [Host.ID: Int] = [:]
    private var confirmations: [UUID: Confirmation] = [:]
    private var observations: [UUID: SFTPEditFileObservation] = [:]
    private var monitoring: Task<Void, Never>?
    private var monitoringEnabled = true

    public init(transfers: SFTPTransferCoordinator, host: ((Host.ID) -> Host?)? = nil) {
        self.transfers = transfers
        self.host = host
    }
    deinit { monitoring?.cancel() }

    public func open(
        _ file: RemoteFile, hostID: Host.ID, connection: SFTPTransferConnection,
        client: any SFTPChannelProtocol, homeDirectory: String? = nil,
        snapshot: SSHAdditionalConnectionSnapshot? = nil
    ) async throws -> URL {
        validateHosts()
        if let existing = model.file(hostID: hostID, path: file.path) {
            guard !existing.isInvalidated,
                matchesDestination(existing.id, connection: connection, snapshot: snapshot)
            else { throw SFTPEditFailure.unavailable }
            return existing.localURL
        }
        let key = Key(hostID: hostID, path: file.path)
        if let task = opening[key] {
            let url = try await task.value
            if let existing = model.file(hostID: hostID, path: file.path),
                !matchesDestination(existing.id, connection: connection, snapshot: snapshot)
            {
                throw SFTPEditFailure.unavailable
            }
            return url
        }
        let generation = generations[hostID, default: 0]
        let originalHost = host?(hostID)
        let task = Task { [self] in
            guard RemoteFileName.isValid(file.name) else { throw CocoaError(.fileWriteInvalidFileName) }
            let original = try await client.attributes(at: file.path)
            guard let original, !original.isDirectory else { throw SFTPEditFailure.unavailable }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TermindEdits", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(file.name)
            let downloadReceipt = SFTPEditTransferReceipt()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                transfers.enqueue(
                    direction: .download, batchID: UUID(), localURL: url,
                    remotePath: file.path, byteCount: original.size, hostID: hostID,
                    connection: connection, scopedRoot: directory, overwrite: false, homeDirectory: homeDirectory,
                    editReceipt: downloadReceipt
                ) { state in
                    switch state {
                    case .completed: continuation.resume()
                    case .failed(let message): continuation.resume(throwing: SFTPError.operation(message))
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    case .queued, .running, .paused: break
                    }
                }
            }
            guard generations[hostID, default: 0] == generation else { throw SFTPEditFailure.unavailable }
            if original.kind == .file {
                // Production downloads report the version from their own open handle; the browser may be closed.
                let downloadedVersion: SFTPFileVersion?
                if let version = downloadReceipt.version {
                    downloadedVersion = version
                } else {
                    downloadedVersion = try await client.attributes(at: file.path).map(SFTPFileVersion.init)
                }
                guard downloadedVersion == SFTPFileVersion(original) else {
                    throw SFTPEditFailure.remoteChanged
                }
                let digest = try await localFiles.digest(url)
                guard generations[hostID, default: 0] == generation else { throw SFTPEditFailure.unavailable }
                if let originalHost { originalHosts[hostID] = originalHost }
                let id = model.register(hostID: hostID, file: original, localURL: url, digest: digest)
                destinations[id] = destination(connection, snapshot: snapshot)
                validateHosts()
                startMonitoring()
            }
            return url
        }
        opening[key] = task
        defer { opening[key] = nil }
        return try await task.value
    }

    public func recheck(force: Bool = true) async {
        validateHosts()
        for entry in model.files {
            do {
                let digest = try await localFiles.digest(entry.localURL, force: force)
                model.update(entry.id) {
                    $0.currentDigest = digest
                    $0.localError = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                model.update(entry.id) { $0.localError = error.localizedDescription }
            }
        }
    }

    public func setMonitoring(_ enabled: Bool) {
        monitoringEnabled = enabled
        monitoring?.cancel()
        monitoring = nil
        observations.removeAll()
        if enabled { startMonitoring() }
    }

    private func startMonitoring() {
        guard monitoringEnabled, !model.files.isEmpty else { return }
        for file in model.files where observations[file.id] == nil {
            observations[file.id] = SFTPEditFileObservation(url: file.localURL) { [weak self] in
                await self?.recheck()
            }
        }
        guard monitoring == nil else { return }
        monitoring = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                tick += 1
                // Re-resolve paths on every pass, including editors' atomic-save replacements.
                // Foreground and upload checks always hash; periodic full checks cover preserved timestamps.
                await self?.recheck(force: tick % 30 == 0)
            }
        }
    }

    private func validateHosts() {
        guard let host else { return }
        for (id, original) in originalHosts {
            if host(id).map({ original.hasSameConnectionRoute(as: $0) }) != true {
                invalidate(hostID: id)
                originalHosts[id] = nil
            }
        }
    }

    public func invalidate(hostID: Host.ID) {
        generations[hostID, default: 0] += 1
        model.invalidate(hostID: hostID)
        for file in model.files where file.hostID == hostID {
            if let id = file.transferID { transfers.cancel(id) }
            confirmations[file.id] = nil
        }
    }

    /// Discard ends tracking. External editors may still own the copy, so never delete it.
    public func discard(_ id: UUID) async {
        guard let file = model.file(id), !file.isPreparing else { return }
        if let transferID = file.transferID {
            guard transfers.sftpTransfers.first(where: { $0.id == transferID })?.state == .paused else { return }
            model.update(id) {
                $0.isPreparing = true
                $0.error = nil
            }
            transfers.cancel(transferID)
            while model.file(id)?.transferID != nil {
                do { try await Task.sleep(for: .milliseconds(20)) } catch {
                    model.update(id) { $0.isPreparing = false }
                    return
                }
            }
            model.update(id) { $0.isPreparing = false }
            // Keep cleanup failures visible, including a possible remote partial-file path.
            guard model.file(id)?.error == nil else { return }
        }
        model.remove(id)
        observations[id] = nil
        confirmations[id] = nil
        destinations[id] = nil
        await localFiles.forget(file.localURL)
        if model.files.isEmpty {
            monitoring?.cancel()
            monitoring = nil
        }
    }

    /// Returns true only when the UI must ask to replace the version just observed.
    public func upload(
        _ id: UUID, connection: SFTPTransferConnection, client: any SFTPChannelProtocol,
        homeDirectory: String? = nil, replacing: Bool = false,
        snapshot: SSHAdditionalConnectionSnapshot? = nil,
        didUpload: @escaping () -> Void = {}
    ) async -> Bool {
        validateHosts()
        guard let entry = model.file(id), !entry.isPreparing, entry.transferID == nil, !entry.isInvalidated else {
            return false
        }
        guard matchesDestination(id, connection: connection, snapshot: snapshot) else { return false }
        model.update(id) {
            $0.isPreparing = true
            $0.error = nil
        }
        var snapshot: SFTPEditLocalFiles.Snapshot?
        defer { model.update(id) { $0.isPreparing = false } }
        do {
            let currentDigest = try await localFiles.digest(entry.localURL)
            model.update(id) { $0.currentDigest = currentDigest }
            guard currentDigest != entry.uploadedDigest else { return false }
            let remote = try await client.attributes(at: entry.remotePath)
            guard remote == nil || remote?.kind == .file else { throw SFTPEditFailure.unsupported }
            let version = remote.map(SFTPFileVersion.init)
            let confirmed = replacing && confirmations[id].map { $0.version == version } == true
            if !confirmed && (version != entry.baseline || version?.modifiedAt == nil) {
                confirmations[id] = Confirmation(version: version)
                return true
            }
            confirmations[id] = nil
            let prepared = try await localFiles.snapshot(entry.localURL)
            snapshot = prepared
            validateHosts()
            guard model.file(id)?.isInvalidated == false else { throw SFTPEditFailure.unavailable }
            let receipt = SFTPEditTransferReceipt()
            let transferID = transfers.enqueue(
                direction: .upload, batchID: UUID(), localURL: prepared.url,
                remotePath: entry.remotePath, byteCount: prepared.size, hostID: entry.hostID,
                connection: connection, scopedRoot: prepared.url.deletingLastPathComponent(), overwrite: remote != nil,
                homeDirectory: homeDirectory,
                editPolicy: SFTPEditUploadPolicy(
                    expected: version, permissions: version?.permissions ?? entry.baseline.permissions),
                editReceipt: receipt
            ) { [weak self, localFiles] state in
                Task { @MainActor in
                    await localFiles.removeSnapshot(prepared)
                    guard let self else { return }
                    await self.recheck()
                    if state == .completed {
                        self.model.didUpload(id, digest: prepared.digest, baseline: receipt.version ?? entry.baseline)
                        didUpload()
                    } else {
                        self.model.update(id) {
                            $0.transferID = nil
                            if case .failed(let message) = state { $0.error = message }
                        }
                    }
                }
            }
            model.update(id) { $0.transferID = transferID }
            return false
        } catch {
            if let snapshot { await localFiles.removeSnapshot(snapshot) }
            model.update(id) { $0.error = error.localizedDescription }
            return false
        }
    }

    private func destination(
        _ connection: SFTPTransferConnection, snapshot: SSHAdditionalConnectionSnapshot?
    ) -> Destination? {
        if let snapshot { return Destination(snapshot) }
        if case .saved(let saved) = connection { return Destination(saved) }
        if case .context(let session) = connection { return Destination(session.snapshot) }
        return nil
    }

    private func matchesDestination(
        _ id: UUID, connection: SFTPTransferConnection, snapshot: SSHAdditionalConnectionSnapshot?
    ) -> Bool {
        guard destinations[id] == destination(connection, snapshot: snapshot) else {
            model.update(id) {
                $0.isInvalidated = true
                $0.error = SFTPEditFailure.unavailable.localizedDescription
            }
            return false
        }
        return true
    }
}
