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
    static let menuKinds: [ConnectionHistoryEntry.Kind] = [.ssh, .mosh, .eternalTerminal, .telnet, .sftp]

    // Trailing swipe actions are declared from the edge outwards, so reversing
    // the menu order keeps the revealed protocol order consistent.
    static let swipeKinds: [ConnectionHistoryEntry.Kind] = [.sftp, .telnet, .eternalTerminal, .mosh, .ssh]

    static func availableMenuKinds(for host: Host) -> [ConnectionHistoryEntry.Kind] {
        menuKinds.filter { isAvailable($0, for: host) }
    }

    static func availableSwipeKinds(for host: Host) -> [ConnectionHistoryEntry.Kind] {
        swipeKinds.filter { isAvailable($0, for: host) }
    }

    static func isAvailable(_ kind: ConnectionHistoryEntry.Kind, for host: Host) -> Bool {
        switch kind {
        case .ssh, .sftp: host.sshEnabled
        case .telnet: host.telnetEnabled
        case .mosh: host.isEnabled(.mosh)
        case .eternalTerminal: host.isEnabled(.eternalTerminal)
        }
    }
}

@MainActor
enum MobileConnectionHistory {
    static func recentHostRows(
        history: ConnectionHistoryModel,
        library: HostLibraryModel,
        limit: Int
    ) -> [MobileRecentHostRow] {
        history.recentLocalHosts(in: library, limit: limit).map { recent in
            let host = recent.host
            let preferredKind = preferredKind(for: host)
            return MobileRecentHostRow(
                entry: recent.entry,
                host: host,
                loginAddress: library.preferredTerminalLoginAddress(for: host),
                preferredKind: preferredKind
            )
        }
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
        .preferredTerminal(for: host)
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
