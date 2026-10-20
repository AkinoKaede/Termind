// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// One SFTP transfer and its current-session history.
///
/// The queue is app-wide rather than per-SFTP workspace: a copy started from one
/// browser should keep running when that workspace is closed. The browser session only
/// enqueues work; a queue region inside an SFTP channel can report app-wide work
/// without making navigation state global.
public nonisolated struct SFTPTransfer: Identifiable, Hashable, Sendable {
    public nonisolated enum Direction: String, Sendable, CaseIterable, Identifiable {
        case upload, download, copy

        public nonisolated var id: String { rawValue }

        public var symbol: String {
            switch self {
            case .upload: "arrow.up.circle"
            case .download: "arrow.down.circle"
            case .copy: "doc.on.doc"
            }
        }
    }

    public nonisolated enum State: Hashable, Sendable {
        case queued
        case running
        case paused
        case completed
        case cancelled
        case failed(String)

        /// Work awaiting admission or moving bytes; paused work is not active.
        public var isActive: Bool {
            self == .queued || self == .running
        }

        /// Only terminal records may be removed from the transfer history.
        public var isFinished: Bool {
            switch self {
            case .completed, .cancelled, .failed: true
            case .queued, .running, .paused: false
            }
        }

        public var label: String {
            switch self {
            case .queued: String(localized: "Queued")
            case .running: String(localized: "Transferring")
            case .paused: String(localized: "Paused")
            case .completed: String(localized: "Done")
            case .cancelled: String(localized: "Cancelled")
            case .failed(let reason): reason
            }
        }

    }

    public var id: UUID = UUID()
    public var batchID: UUID = UUID()
    public var hostID: Host.ID?
    public var sourceHostID: Host.ID?
    public var destinationHostID: Host.ID?
    public var direction: Direction = .upload
    public var localPath: String
    public var remotePath: String
    public var sourceHomeDirectory: String?
    public var destinationHomeDirectory: String?
    public var byteCount: Int64 = 0
    public var transferredBytes: Int64 = 0
    public var bytesPerSecond: Int64 = 0
    public var state: State = .queued
    public var queuedAt: Date = Date(timeIntervalSince1970: 0)
    public var completedAt: Date?

    /// The name of the file being moved, taken from whichever side is the source.
    public var fileName: String {
        let source = direction == .download ? remotePath : localPath
        return (source as NSString).lastPathComponent
    }

    public var progress: Double {
        guard byteCount > 0 else { return state == .completed ? 1 : 0 }
        return min(1, Double(transferredBytes) / Double(byteCount))
    }

    public var relatedHostIDs: Set<Host.ID> {
        Set([hostID, sourceHostID, destinationHostID].compactMap { $0 })
    }

    public func involves(_ hostID: Host.ID) -> Bool {
        relatedHostIDs.contains(hostID)
    }
    public init(
        id: UUID = UUID(), batchID: UUID = UUID(), hostID: Host.ID? = nil, sourceHostID: Host.ID? = nil,
        destinationHostID: Host.ID? = nil, direction: Direction = .upload, localPath: String, remotePath: String,
        sourceHomeDirectory: String? = nil, destinationHomeDirectory: String? = nil, byteCount: Int64 = 0,
        transferredBytes: Int64 = 0, bytesPerSecond: Int64 = 0, state: State = .queued,
        queuedAt: Date = Date(timeIntervalSince1970: 0), completedAt: Date? = nil
    ) {
        self.id = id
        self.batchID = batchID
        self.hostID = hostID
        self.sourceHostID = sourceHostID
        self.destinationHostID = destinationHostID
        self.direction = direction
        self.localPath = localPath
        self.remotePath = remotePath
        self.sourceHomeDirectory = sourceHomeDirectory
        self.destinationHomeDirectory = destinationHomeDirectory
        self.byteCount = byteCount
        self.transferredBytes = transferredBytes
        self.bytesPerSecond = bytesPerSecond
        self.state = state
        self.queuedAt = queuedAt
        self.completedAt = completedAt
    }

}
