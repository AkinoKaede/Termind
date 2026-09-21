import TermindApplication
import TermindDomain

struct MobileConnectionHistoryRow: Identifiable {
    let entry: ConnectionHistoryEntry
    let host: Host
    let loginAddress: String

    var id: ConnectionHistoryEntry.ID { entry.id }
    var canOpen: Bool {
        MobileConnectionHistoryActionPolicy.isAvailable(entry.kind, for: host)
    }
}

enum MobileConnectionHistoryActionPolicy {
    static let menuKinds: [ConnectionHistoryEntry.Kind] = [.ssh, .telnet, .sftp]

    // Trailing swipe actions are declared from the edge outwards, so reversing
    // the menu order keeps the revealed protocol order consistent.
    static let swipeKinds: [ConnectionHistoryEntry.Kind] = [.sftp, .telnet, .ssh]

    static func isAvailable(_ kind: ConnectionHistoryEntry.Kind, for host: Host) -> Bool {
        switch kind {
        case .ssh, .sftp: host.sshEnabled
        case .telnet: host.telnetEnabled
        }
    }
}

@MainActor
enum MobileConnectionHistory {
    private struct Key: Hashable {
        let hostID: Host.ID
        let kind: ConnectionHistoryEntry.Kind
    }

    static func rows(
        entries: [ConnectionHistoryEntry],
        library: HostLibraryModel,
        limit: Int
    ) -> [MobileConnectionHistoryRow] {
        guard limit > 0 else { return [] }

        var seen: Set<Key> = []
        var rows: [MobileConnectionHistoryRow] = []
        for entry in entries {
            guard let host = library.host(entry.hostID) else { continue }
            guard seen.insert(Key(hostID: entry.hostID, kind: entry.kind)).inserted else { continue }
            rows.append(
                MobileConnectionHistoryRow(
                    entry: entry,
                    host: host,
                    loginAddress: library.loginAddress(
                        for: host, protocol: entry.kind == .telnet ? .telnet : .ssh)
                ))
            if rows.count == limit { break }
        }
        return rows
    }
}
