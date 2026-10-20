// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Observation
import TermindDomain

import struct TermindDomain.Host

public struct RecentConnectionHost: Identifiable {
    public let entry: ConnectionHistoryEntry
    public let host: Host

    public var id: Host.ID { host.id }
}

@MainActor
@Observable
public final class ConnectionHistoryModel {
    public static let limit = HistoryLimits.retainedEntries

    private let repository: any ConnectionHistoryRepository
    public private(set) var menuReferenceDate = Date()
    public let sourceDeviceID: UUID
    private var cachedEntries: [ConnectionHistoryEntry] = []
    public private(set) var revision: UInt64 = 0
    public private(set) var storageError: String?

    public init(
        entries: [ConnectionHistoryEntry] = [],
        repository: (any ConnectionHistoryRepository)? = nil,
        sourceDeviceID: UUID = UUID()
    ) {
        self.repository = repository ?? InMemoryConnectionHistoryRepository(entries: entries)
        self.sourceDeviceID = sourceDeviceID
        do {
            try self.repository.trim(to: Self.limit)
        } catch {
            storageError = error.localizedDescription
        }
        // A failed maintenance write must not hide readable existing history.
        do {
            cachedEntries = try self.repository.entries()
        } catch {
            storageError = error.localizedDescription
        }
    }

    public func refreshMenuDate() { menuReferenceDate = Date() }

    public func entries() -> [ConnectionHistoryEntry] {
        _ = revision
        return cachedEntries
    }

    public func entries(for hostID: Host.ID) -> [ConnectionHistoryEntry] {
        entries().filter { $0.hostID == hostID }
    }

    public func isLocal(_ entry: ConnectionHistoryEntry) -> Bool {
        entry.sourceDeviceID == sourceDeviceID
    }

    public func localEntries() -> [ConnectionHistoryEntry] {
        entries().filter(isLocal)
    }

    /// The latest local connection for each saved Host, in connection order.
    public func recentLocalHosts(in library: HostLibraryModel, limit: Int) -> [RecentConnectionHost] {
        guard limit > 0 else { return [] }

        var seen = Set<Host.ID>()
        var hosts: [RecentConnectionHost] = []
        for entry in localEntries() {
            guard let host = library.host(entry.hostID), seen.insert(entry.hostID).inserted else { continue }
            hosts.append(RecentConnectionHost(entry: entry, host: host))
            if hosts.count == limit { break }
        }
        return hosts
    }

    public func mostRecentDate(for hostID: Host.ID) -> Date? {
        entries().first { $0.hostID == hostID }?.connectedAt
    }

    public func mostRecentLocalDate(for hostID: Host.ID) -> Date? {
        localEntries().first { $0.hostID == hostID }?.connectedAt
    }

    @discardableResult
    public func record(
        kind: ConnectionHistoryEntry.Kind, for hostID: Host.ID,
        at date: Date = Date()
    ) -> ConnectionHistoryEntry? {
        let entry = ConnectionHistoryEntry(
            hostID: hostID, kind: kind, connectedAt: date,
            sourceDeviceID: sourceDeviceID
        )
        do {
            try repository.insert(entry, limit: Self.limit)
            reload()
            return entry
        } catch {
            storageError = error.localizedDescription
            return nil
        }
    }

    public func end(_ id: ConnectionHistoryEntry.ID, at date: Date = Date()) {
        do {
            try repository.end(id, at: date)
            reload()
        } catch { storageError = error.localizedDescription }
    }

    /// Refresh outside rendering, after a local write or a committed sync transaction.
    /// View reads must never publish cache or error changes into an active graph update.
    public func reload() {
        do {
            cachedEntries = try repository.entries()
            storageError = nil
        } catch {
            cachedEntries = []
            storageError = error.localizedDescription
        }
        revision &+= 1
    }

    public func delete(_ id: ConnectionHistoryEntry.ID) {
        do {
            try repository.delete(id)
            reload()
        } catch { storageError = error.localizedDescription }
    }

    public func clear(for hostID: Host.ID) {
        do {
            try repository.clear(for: hostID)
            reload()
        } catch { storageError = error.localizedDescription }
    }

    public func clearAll() {
        do {
            try repository.clearAll()
            cachedEntries = []
            storageError = nil
            revision &+= 1
        } catch { storageError = error.localizedDescription }
    }
}
