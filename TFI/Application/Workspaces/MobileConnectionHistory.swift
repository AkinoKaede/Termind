import TermindApplication
import TermindDomain

struct MobileConnectionHistoryRow: Identifiable {
    let entry: ConnectionHistoryEntry
    let host: Host
    let loginAddress: String

    var id: ConnectionHistoryEntry.ID { entry.id }
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
                    loginAddress: library.loginAddress(for: host)
                ))
            if rows.count == limit { break }
        }
        return rows
    }
}
