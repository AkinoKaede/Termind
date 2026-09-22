import TermindApplication
import TermindDomain

struct MobileConnectionHistoryRow: Identifiable {
    let entry: ConnectionHistoryEntry
    let host: Host
    let loginAddress: String
    let sourceDeviceName: String?

    var id: ConnectionHistoryEntry.ID { entry.id }
    var canOpen: Bool {
        MobileConnectionHistoryActionPolicy.isAvailable(entry.kind, for: host)
    }
}

struct MobileRecentHostRow: Identifiable {
    let entry: ConnectionHistoryEntry
    let host: Host
    let loginAddress: String
    let preferredKind: ConnectionHistoryEntry.Kind?

    var id: Host.ID { host.id }
    var canOpen: Bool { preferredKind != nil }
}

enum MobileConnectionHistoryActionPolicy {
    static let menuKinds: [ConnectionHistoryEntry.Kind] = [.ssh, .telnet, .sftp]

    // Trailing swipe actions are declared from the edge outwards, so reversing
    // the menu order keeps the revealed protocol order consistent.
    static let swipeKinds: [ConnectionHistoryEntry.Kind] = [.sftp, .telnet, .ssh]

    static func availableSwipeKinds(for host: Host) -> [ConnectionHistoryEntry.Kind] {
        swipeKinds.filter { isAvailable($0, for: host) }
    }

    static func isAvailable(_ kind: ConnectionHistoryEntry.Kind, for host: Host) -> Bool {
        switch kind {
        case .ssh, .sftp: host.sshEnabled
        case .telnet: host.telnetEnabled
        }
    }
}

@MainActor
enum MobileConnectionHistory {
    static func recentHostRows(
        entries: [ConnectionHistoryEntry],
        library: HostLibraryModel,
        limit: Int
    ) -> [MobileRecentHostRow] {
        guard limit > 0 else { return [] }

        var seen = Set<Host.ID>()
        var rows: [MobileRecentHostRow] = []
        for entry in entries {
            guard let host = library.host(entry.hostID) else { continue }
            guard seen.insert(host.id).inserted else { continue }
            let preferredKind = preferredKind(for: host)
            rows.append(
                MobileRecentHostRow(
                    entry: entry,
                    host: host,
                    loginAddress: library.preferredTerminalLoginAddress(for: host),
                    preferredKind: preferredKind
                ))
            if rows.count == limit { break }
        }
        return rows
    }

    static func eventRows(
        history: ConnectionHistoryModel,
        devices: DeviceDirectoryModel,
        library: HostLibraryModel,
        query: String = "",
        limit: Int
    ) -> [MobileConnectionHistoryRow] {
        guard limit > 0 else { return [] }
        var rows: [MobileConnectionHistoryRow] = []
        for entry in history.entries() {
            guard let host = library.host(entry.hostID) else { continue }
            let loginAddress = library.loginAddress(
                for: host, protocol: entry.kind == .telnet ? .telnet : .ssh)
            let sourceDeviceName = devices.name(for: entry.sourceDeviceID)
            guard
                query.isEmpty
                    || matches(
                        entry, host: host, loginAddress: loginAddress,
                        sourceDeviceName: sourceDeviceName, query: query)
            else {
                continue
            }
            rows.append(
                MobileConnectionHistoryRow(
                    entry: entry, host: host, loginAddress: loginAddress,
                    sourceDeviceName: sourceDeviceName))
            if rows.count == limit { break }
        }
        return rows
    }

    static func preferredKind(for host: Host) -> ConnectionHistoryEntry.Kind? {
        switch host.preferredTerminalProtocol {
        case .ssh: .ssh
        case .telnet: .telnet
        case nil: nil
        }
    }

    private static func matches(
        _ entry: ConnectionHistoryEntry, host: Host, loginAddress: String,
        sourceDeviceName: String?, query: String
    ) -> Bool {
        host.matches(query)
            || loginAddress.localizedCaseInsensitiveContains(query)
            || entry.kind.label.localizedCaseInsensitiveContains(query)
            || sourceDeviceName?.localizedCaseInsensitiveContains(query) == true
    }
}
