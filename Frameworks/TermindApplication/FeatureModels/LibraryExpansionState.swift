import Foundation
import TermindDomain

/// Device-local presentation state for the Hosts and Snippets libraries.
///
/// The Vault still carries the legacy `isExpanded` fields for wire and schema
/// compatibility, but those values are imported only once. Every later change
/// belongs to this installation and never enters a Vault transaction.
struct LibraryExpansionState {
    private struct Snapshot: Codable, Equatable {
        var collapsedHostGroupIDs: Set<HostGroup.ID> = []
        var collapsedSnippetPackageIDs: Set<SnippetPackage.ID> = []
        var hostsUngroupedExpanded = true
        var snippetsUngroupedExpanded = true
    }

    static let storageKey = "library.expansionState.v1"
    static let migrationKey = "library.expansionState.migrated.v1"

    private let defaults: UserDefaults?
    private var snapshot: Snapshot

    init(
        defaults: UserDefaults? = nil,
        legacyGroups: [HostGroup] = [],
        legacySnippetPackages: [SnippetPackage] = []
    ) {
        self.defaults = defaults

        if let defaults, defaults.bool(forKey: Self.migrationKey) {
            if let data = defaults.data(forKey: Self.storageKey),
                let decoded = try? JSONDecoder().decode(Snapshot.self, from: data)
            {
                snapshot = decoded
            } else {
                snapshot = Snapshot()
                persist()
            }
            return
        }

        snapshot = Snapshot(
            collapsedHostGroupIDs: Set(legacyGroups.filter { !$0.isExpanded }.map(\.id)),
            collapsedSnippetPackageIDs: Set(
                legacySnippetPackages.filter { !$0.isExpanded }.map(\.id)
            )
        )
        persist()
        defaults?.set(true, forKey: Self.migrationKey)
    }

    func isHostGroupExpanded(_ id: HostGroup.ID) -> Bool {
        !snapshot.collapsedHostGroupIDs.contains(id)
    }

    func isSnippetPackageExpanded(_ id: SnippetPackage.ID) -> Bool {
        !snapshot.collapsedSnippetPackageIDs.contains(id)
    }

    var isHostsUngroupedExpanded: Bool { snapshot.hostsUngroupedExpanded }
    var isSnippetsUngroupedExpanded: Bool { snapshot.snippetsUngroupedExpanded }

    mutating func setHostGroupExpanded(_ expanded: Bool, for id: HostGroup.ID) {
        guard Self.set(expanded, for: id, in: &snapshot.collapsedHostGroupIDs) else { return }
        persist()
    }

    mutating func setSnippetPackageExpanded(_ expanded: Bool, for id: SnippetPackage.ID) {
        guard Self.set(expanded, for: id, in: &snapshot.collapsedSnippetPackageIDs) else { return }
        persist()
    }

    mutating func setSnippetPackagesExpanded(_ ids: Set<SnippetPackage.ID>) {
        let previous = snapshot.collapsedSnippetPackageIDs
        snapshot.collapsedSnippetPackageIDs.subtract(ids)
        guard snapshot.collapsedSnippetPackageIDs != previous else { return }
        persist()
    }

    mutating func setHostsUngroupedExpanded(_ expanded: Bool) {
        guard snapshot.hostsUngroupedExpanded != expanded else { return }
        snapshot.hostsUngroupedExpanded = expanded
        persist()
    }

    mutating func setSnippetsUngroupedExpanded(_ expanded: Bool) {
        guard snapshot.snippetsUngroupedExpanded != expanded else { return }
        snapshot.snippetsUngroupedExpanded = expanded
        persist()
    }

    mutating func reconcile(
        hostGroupIDs: Set<HostGroup.ID>,
        snippetPackageIDs: Set<SnippetPackage.ID>
    ) {
        let previous = snapshot
        snapshot.collapsedHostGroupIDs.formIntersection(hostGroupIDs)
        snapshot.collapsedSnippetPackageIDs.formIntersection(snippetPackageIDs)
        guard snapshot != previous else { return }
        persist()
    }

    private static func set<ID: Hashable>(
        _ expanded: Bool, for id: ID, in collapsed: inout Set<ID>
    ) -> Bool {
        expanded ? collapsed.remove(id) != nil : collapsed.insert(id).inserted
    }

    private func persist() {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
