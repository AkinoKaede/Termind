// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindDomain

/// Admit new operations without cancelling a transfer already delegated to the channel.
nonisolated final class AccessControlledSFTPChannel: SFTPChannelProtocol, Sendable {
    private let channel: any SFTPChannelProtocol
    private let accessCheck: HostOperationAccessCheck?

    init(channel: any SFTPChannelProtocol, accessCheck: HostOperationAccessCheck?) {
        self.channel = channel
        self.accessCheck = accessCheck
    }

    func disconnect() async { await channel.disconnect() }

    public func openSiblingChannel() async throws -> any SFTPChannelProtocol {
        AccessControlledSFTPChannel(
            channel: try await connectedChannel().openSiblingChannel(), accessCheck: accessCheck)
    }

    public func homeDirectory() async throws -> String {
        try await connectedChannel().homeDirectory()
    }

    public func listDirectory(at path: String) async throws -> [RemoteFile] {
        try await connectedChannel().listDirectory(at: path)
    }

    public func attributes(at path: String) async throws -> RemoteFile? {
        try await connectedChannel().attributes(at: path)
    }

    public func readFile(at path: String, maximumBytes: Int) async throws -> Data {
        try await connectedChannel().readFile(at: path, maximumBytes: maximumBytes)
    }

    public func readTextPage(at path: String, offset: Int, limit: Int) async throws -> AgentTextPage {
        try await connectedChannel().readTextPage(at: path, offset: offset, limit: limit)
    }

    public func writeFile(_ data: Data, at path: String, overwrite: Bool) async throws {
        try await connectedChannel().writeFile(data, at: path, overwrite: overwrite)
    }

    public func setPermissions(at path: String, to permissions: UInt32) async throws {
        try await connectedChannel().setPermissions(at: path, to: permissions)
    }

    public func createDirectory(at path: String) async throws {
        try await connectedChannel().createDirectory(at: path)
    }

    public func rename(from source: String, to destination: String, overwrite: Bool) async throws {
        try await connectedChannel().rename(
            from: source, to: destination, overwrite: overwrite)
    }

    public func removeFile(at path: String) async throws {
        try await connectedChannel().removeFile(at: path)
    }

    public func removeDirectory(at path: String) async throws {
        try await connectedChannel().removeDirectory(at: path)
    }

    public func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try await connectedChannel().uploadFile(
            from: localURL, to: remotePath, overwrite: overwrite,
            cancellation: cancellation, resume: resume, progress: progress)
    }

    public func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try await connectedChannel().uploadFile(
            from: localURL, to: remotePath, overwrite: overwrite,
            cancellation: cancellation, progress: progress)
    }

    public func uploadStream(
        fromSocket socket: Int32, to remotePath: String, byteCount: Int64,
        overwrite: Bool, cancellation: TransferCancellationToken,
        resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void,
        sourceSucceeded: @escaping @Sendable () -> Bool
    ) async throws {
        try await connectedChannel().uploadStream(
            fromSocket: socket, to: remotePath, byteCount: byteCount,
            overwrite: overwrite, cancellation: cancellation, resume: resume,
            progress: progress, sourceSucceeded: sourceSucceeded)
    }

    public func uploadStream(
        fromSocket socket: Int32, to remotePath: String, byteCount: Int64,
        overwrite: Bool, cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void,
        sourceSucceeded: @escaping @Sendable () -> Bool
    ) async throws {
        try await connectedChannel().uploadStream(
            fromSocket: socket, to: remotePath, byteCount: byteCount,
            overwrite: overwrite, cancellation: cancellation,
            progress: progress, sourceSucceeded: sourceSucceeded)
    }

    public func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try await connectedChannel().downloadFile(
            from: remotePath, to: localURL, overwrite: overwrite,
            cancellation: cancellation, resume: resume, progress: progress)
    }

    public func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try await connectedChannel().downloadFile(
            from: remotePath, to: localURL, overwrite: overwrite,
            cancellation: cancellation, progress: progress)
    }

    public func openDownloadStream(
        at path: String, maximumBytes: Int64,
        cancellation: TransferCancellationToken
    ) async throws -> any SFTPDownloadStream {
        try await connectedChannel().openDownloadStream(
            at: path, maximumBytes: maximumBytes, cancellation: cancellation)
    }

    public func copyFile(
        from sourcePath: String, to destinationPath: String,
        on destination: any SFTPChannelProtocol, byteCount: Int64,
        overwrite: Bool, cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        let destinationChannel =
            if let destination = destination as? AccessControlledSFTPChannel {
                try destination.connectedChannel()
            } else {
                destination
            }
        try await connectedChannel().copyFile(
            from: sourcePath, to: destinationPath, on: destinationChannel,
            byteCount: byteCount, overwrite: overwrite,
            cancellation: cancellation, progress: progress)
    }

    private func connectedChannel() throws -> any SFTPChannelProtocol {
        try accessCheck?()
        return channel
    }
}
