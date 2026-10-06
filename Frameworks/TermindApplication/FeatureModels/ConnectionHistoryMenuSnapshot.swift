import Foundation
import TermindDomain

import struct TermindDomain.Host

public struct ConnectionHistoryMenuRow: Identifiable {
    public let entry: ConnectionHistoryEntry
    public let host: Host
    public let deviceName: String?
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

/// A read-only projection. Synced events never become events from this launch.
public struct ConnectionHistoryMenuSnapshot {
    public let currentLaunch: [ConnectionHistoryMenuRow]
    public let days: [ConnectionHistoryMenuDay]

    @MainActor
    public init(
        history: ConnectionHistoryModel, library: HostLibraryModel, devices: DeviceDirectoryModel,
        now: Date? = nil, calendar: Calendar = .current
    ) {
        let rows = history.entries().sorted {
            if $0.connectedAt != $1.connectedAt { return $0.connectedAt > $1.connectedAt }
            return $0.id.uuidString < $1.id.uuidString
        }.compactMap { entry -> ConnectionHistoryMenuRow? in
            guard let host = library.host(entry.hostID) else { return nil }
            return ConnectionHistoryMenuRow(
                entry: entry, host: host,
                deviceName: history.isLocal(entry) ? nil : devices.name(for: entry.sourceDeviceID))
        }
        currentLaunch = rows.filter { history.currentLaunchEntryIDs.contains($0.id) }
        let older = rows.filter { !history.currentLaunchEntryIDs.contains($0.id) }
        let grouped = Dictionary(grouping: older) { calendar.startOfDay(for: $0.entry.connectedAt) }
        days = grouped.keys.sorted(by: >).map { date in
            ConnectionHistoryMenuDay(
                date: date, isToday: calendar.isDate(date, inSameDayAs: now ?? history.menuReferenceDate),
                rows: grouped[date] ?? [])
        }
    }
}
