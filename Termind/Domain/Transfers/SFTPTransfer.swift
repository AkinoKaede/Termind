import Foundation

/// One queued or running SFTP transfer.
///
/// The queue is app-wide rather than per-SFTP-tab: a copy started from one
/// browser should keep running when that tab is closed. The browser session only
/// enqueues work; a queue region inside an SFTP session can report app-wide work
/// without making navigation state global.
nonisolated struct SFTPTransfer: Identifiable, Hashable, Sendable {
    nonisolated enum Direction: String, Sendable, CaseIterable, Identifiable {
        case upload, download, copy

        nonisolated var id: String { rawValue }

        var displayName: String {
            switch self {
            case .upload: String(localized: "Upload")
            case .download: String(localized: "Download")
            case .copy: String(localized: "Copy")
            }
        }

        var symbol: String {
            switch self {
            case .upload: "arrow.up.circle"
            case .download: "arrow.down.circle"
            case .copy: "doc.on.doc"
            }
        }
    }

    nonisolated enum State: Hashable, Sendable {
        case queued
        case running
        case paused
        case completed
        case cancelled
        case failed(String)

        var label: String {
            switch self {
            case .queued: String(localized: "Queued")
            case .running: String(localized: "Transferring")
            case .paused: String(localized: "Paused")
            case .completed: String(localized: "Done")
            case .cancelled: String(localized: "Cancelled")
            case .failed(let reason): reason
            }
        }

        /// Whether Batch Startup should pick this one up. Completed and already
        /// running transfers are skipped; a failed one is a retry, which is
        /// exactly what a batch start is for after a dropped connection.
        var isStartable: Bool {
            switch self {
            case .queued, .paused, .failed: true
            case .running, .completed, .cancelled: false
            }
        }
    }

    var id: UUID = UUID()
    var batchID: UUID = UUID()
    var hostID: Host.ID?
    var sourceHostID: Host.ID?
    var destinationHostID: Host.ID?
    var direction: Direction = .upload
    var localPath: String
    var remotePath: String
    var byteCount: Int64 = 0
    var transferredBytes: Int64 = 0
    var bytesPerSecond: Int64 = 0
    var state: State = .queued
    var queuedAt: Date = Date(timeIntervalSince1970: 0)
    var completedAt: Date?

    /// The name of the file being moved, taken from whichever side is the source.
    var fileName: String {
        let source = direction == .download ? remotePath : localPath
        return (source as NSString).lastPathComponent
    }

    var progress: Double {
        guard byteCount > 0 else { return state == .completed ? 1 : 0 }
        return min(1, Double(transferredBytes) / Double(byteCount))
    }

    var route: String {
        switch direction {
        case .upload: "\(localPath) → \(remotePath)"
        case .download: "\(remotePath) → \(localPath)"
        case .copy: "\(localPath) → \(remotePath)"
        }
    }

    var relatedHostIDs: Set<Host.ID> {
        Set([hostID, sourceHostID, destinationHostID].compactMap { $0 })
    }

    func involves(_ hostID: Host.ID) -> Bool {
        relatedHostIDs.contains(hostID)
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return localPath.lowercased().contains(q) || remotePath.lowercased().contains(q)
    }
}
