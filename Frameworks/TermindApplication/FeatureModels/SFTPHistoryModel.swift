import Foundation
import TermindDomain

/// Successful browse/open operations from one live SFTP session only.
@MainActor
@Observable
public final class SFTPHistoryModel {
    public static let perSessionLimit = HistoryLimits.retainedEntries
    public let sessionID: UUID
    public private(set) var revision: UInt64 = 0
    private var values: [SFTPHistoryEntry]
    private var isClosed = false

    public init(sessionID: UUID = UUID(), entries: [SFTPHistoryEntry] = []) {
        self.sessionID = sessionID
        values = Array(entries.filter { $0.sessionID == sessionID }.prefix(Self.perSessionLimit))
    }

    public func entries(matching query: String = "") -> [SFTPHistoryEntry] {
        query.isEmpty ? values : values.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    public func record(kind: SFTPHistoryEntry.Kind, path: String, at date: Date = Date()) {
        guard !isClosed else { return }
        let path = RemotePath.normalized(path)
        values.removeAll { $0.kind == kind && $0.path == path }
        values.insert(SFTPHistoryEntry(sessionID: sessionID, kind: kind, path: path, visitedAt: date), at: 0)
        if values.count > Self.perSessionLimit { values.removeLast(values.count - Self.perSessionLimit) }
        revision &+= 1
    }

    public func close() {
        isClosed = true
        values.removeAll()
        revision &+= 1
    }
}
