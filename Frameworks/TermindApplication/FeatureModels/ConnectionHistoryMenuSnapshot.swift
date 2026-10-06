import Foundation
import TermindDomain

import struct TermindDomain.Host

public struct ConnectionHistoryMenuRow: Identifiable {
    public let entry: ConnectionHistoryEntry
    public let host: Host
    public var id: UUID { entry.id }
    public var canOpen: Bool {
        switch entry.kind {
        case .ssh, .sftp: host.sshEnabled
        case .telnet: host.telnetEnabled
        }
    }
}

public struct ConnectionHistoryMenuDay: Identifiable {
    public let date: Date
    public let isToday: Bool
    public let rows: [ConnectionHistoryMenuRow]
    public var id: Date { date }
}

/// The latest records from today, with overflow and earlier records grouped by local calendar day.
public struct ConnectionHistoryMenuSnapshot {
    public let recentToday: [ConnectionHistoryMenuRow]
    public let days: [ConnectionHistoryMenuDay]

    @MainActor
    public init(
        history: ConnectionHistoryModel, library: HostLibraryModel,
        now: Date? = nil, calendar: Calendar = .current
    ) {
        let rows = history.entries().sorted {
            if $0.connectedAt != $1.connectedAt { return $0.connectedAt > $1.connectedAt }
            return $0.id.uuidString < $1.id.uuidString
        }.compactMap { entry -> ConnectionHistoryMenuRow? in
            guard let host = library.host(entry.hostID) else { return nil }
            return ConnectionHistoryMenuRow(entry: entry, host: host)
        }
        let referenceDate = now ?? history.menuReferenceDate
        recentToday = Array(
            rows.filter { calendar.isDate($0.entry.connectedAt, inSameDayAs: referenceDate) }.prefix(15))
        let displayed = Set(recentToday.map(\.id))
        let older = rows.filter { !displayed.contains($0.id) }
        let grouped = Dictionary(grouping: older) { calendar.startOfDay(for: $0.entry.connectedAt) }
        days = grouped.keys.sorted(by: >).map { date in
            ConnectionHistoryMenuDay(
                date: date, isToday: calendar.isDate(date, inSameDayAs: referenceDate),
                rows: grouped[date] ?? [])
        }
    }
}
