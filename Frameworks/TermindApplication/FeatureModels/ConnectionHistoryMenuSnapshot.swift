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
        case .mosh: host.isEnabled(.mosh)
        case .eternalTerminal: host.isEnabled(.eternalTerminal)
        }
    }
}

public struct ConnectionHistoryMenuDay: Identifiable {
    public let date: Date
    public let isToday: Bool
    public let rows: [ConnectionHistoryMenuRow]
    public var id: Date { date }
}

/// Today’s latest records, with overflow and the preceding six days grouped by local calendar day.
public struct ConnectionHistoryMenuSnapshot {
    public let recentToday: [ConnectionHistoryMenuRow]
    public let days: [ConnectionHistoryMenuDay]

    @MainActor
    public init(
        history: ConnectionHistoryModel, library: HostLibraryModel,
        now: Date? = nil, calendar: Calendar = .current
    ) {
        let referenceDate = now ?? history.menuReferenceDate
        let today = calendar.startOfDay(for: referenceDate)
        let firstDay = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? referenceDate
        let rows = history.entries().filter {
            $0.connectedAt >= firstDay && $0.connectedAt < end
        }.sorted {
            if $0.connectedAt != $1.connectedAt { return $0.connectedAt > $1.connectedAt }
            return $0.id.uuidString < $1.id.uuidString
        }.compactMap { entry -> ConnectionHistoryMenuRow? in
            guard let host = library.host(entry.hostID) else { return nil }
            return ConnectionHistoryMenuRow(entry: entry, host: host)
        }
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
