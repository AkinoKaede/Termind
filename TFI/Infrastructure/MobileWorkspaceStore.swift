import Foundation
import TermindDomain
import TermindInfrastructure

/// Device-local connection intent only. Credentials, commands and live session state never enter this store.
/// One app-owned store writes the complete snapshot, so saves from different windows cannot overwrite each other.
@MainActor
final class MobileWorkspaceStore {
    static let key = "mobile.workspaces.v1"

    struct Snapshot: Codable, Equatable {
        var version = 2
        var sessions: [String: [MobileWorkspaceDescriptor]] = [:]
        /// Legacy records have no owner until the first native scene session binds.
        var unassigned: [MobileWorkspaceDescriptor] = []
    }

    private struct Version: Decodable { var version: Int }
    private struct VersionOne: Decodable {
        var version: Int
        var workspaces: [MobileWorkspaceDescriptor]
    }

    private enum StoreError: Error { case invalidSnapshot }
    let recentlyClosed: RecentlyClosedStore<RecentlyClosedRecord<MobileWorkspaceDescriptor>>
    private let defaults: UserDefaults?
    private var canSave = true

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        recentlyClosed = RecentlyClosedStore(defaults: defaults, key: "mobile.recentlyClosed.v2")
    }

    func load() throws -> Snapshot {
        do {
            guard let value = defaults?.object(forKey: Self.key) else {
                canSave = true
                return Snapshot()
            }
            guard let data = value as? Data else { throw StoreError.invalidSnapshot }
            let decoder = JSONDecoder()
            let snapshot: Snapshot
            if let version = try? decoder.decode(Version.self, from: data) {
                switch version.version {
                case 1:
                    snapshot = Snapshot(unassigned: try decoder.decode(VersionOne.self, from: data).workspaces)
                case 2:
                    snapshot = try decoder.decode(Snapshot.self, from: data)
                default:
                    throw StoreError.invalidSnapshot
                }
            } else {
                snapshot = Snapshot(unassigned: try decoder.decode([MobileWorkspaceDescriptor].self, from: data))
            }
            try validate(snapshot)
            canSave = true
            // Migration is committed together with the first window's ownership, never during a read.
            return snapshot
        } catch {
            canSave = false
            throw error
        }
    }

    func save(_ snapshot: Snapshot) throws {
        guard canSave else { throw StoreError.invalidSnapshot }
        try validate(snapshot)
        let data = try JSONEncoder().encode(snapshot)
        defaults?.set(data, forKey: Self.key)
    }

    private func validate(_ snapshot: Snapshot) throws {
        let descriptors = snapshot.unassigned + snapshot.sessions.values.flatMap { $0 }
        guard snapshot.version == 2,
            snapshot.sessions.keys.allSatisfy({ !$0.isEmpty }),
            Set(descriptors.map(\.id)).count == descriptors.count
        else { throw StoreError.invalidSnapshot }
    }
}
