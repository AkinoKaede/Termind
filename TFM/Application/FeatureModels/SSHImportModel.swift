import Foundation
import TermindDomain

import struct TermindDomain.Host

@Observable
final class SSHImportModel {
    var items: [SSHImportItem] = []
    var expanded = Set(SSHImportCategory.allCases)
    var storage: KeyStorage = .iCloud
    private(set) var isWorking = false
    private(set) var error: String?
    private(set) var completed = false
    private(set) var importedCount = 0
    private let library: HostLibraryModel
    private let reader: any SSHImportReading
    private var root: URL?
    private var grants: [URL] = []
    var sourcePath: String? { root?.path }
    private var knownHostsOnly = false
    private var jumpIDs: [String: UUID] = [:]

    init(library: HostLibraryModel, reader: any SSHImportReading) {
        self.library = library
        self.reader = reader
    }

    func scan(_ url: URL, knownHostsOnly: Bool) async {
        guard !isWorking else { return }
        grants = []
        items = []
        completed = false
        root = url
        self.knownHostsOnly = knownHostsOnly
        await reload()
    }

    func authorize(_ url: URL) async {
        grants.append(url)
        await reload()
    }

    private func reload() async {
        guard let root else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let previous = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            items = try await reader.scan(root: root, knownHostsOnly: knownHostsOnly, grants: grants)
            addJumpDestinations()
            for index in items.indices {
                if let old = previous[items[index].id] {
                    items[index].selected = old.selected
                    items[index].acceptedWarnings = old.acceptedWarnings
                    items[index].preferredKeyID = old.preferredKeyID
                    if items[index].host != nil { items[index].name = old.name }
                }
            }
            refreshDuplicates()
        } catch {
            self.error =
                (error as? SSHImportSourceError)?.localizedDescription
                ?? String(localized: "The SSH files could not be read.")
        }
    }

    private func addJumpDestinations() {
        let originalIDs = items.filter { $0.host != nil }.map(\.id)
        let jumps = items.compactMap(\.host).flatMap(\.jumps)
        for jump in jumps where !items.contains(where: { $0.host?.alias == jump }) {
            let userParts = jump.split(separator: "@", maxSplits: 1).map(String.init)
            let address = userParts.last ?? jump
            let host: String
            let port: Int?
            if address.hasPrefix("["), let endpoint = SSHImportParser.endpoint(address) {
                (host, port) = endpoint
            } else if address.filter({ $0 == ":" }).count == 1 {
                let parts = address.split(separator: ":").map(String.init)
                host = parts.first ?? address
                port = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
            } else {
                host = address
                port = nil
            }
            let saved = library.hosts.first { $0.name == host }
            let identity = saved?.identityID.flatMap(library.identity)
            let base = items.first { $0.host?.alias == host }?.host
            let value = SSHImportedHost(
                alias: jump, hostname: base?.hostname ?? saved?.host ?? host,
                port: port ?? base?.port ?? saved?.port ?? 22,
                username: userParts.count == 2 ? userParts[0] : base?.username ?? identity?.username ?? NSUserName(),
                identityPaths: base?.identityPaths ?? [], existingKeyID: identity?.keyID)
            let id = jumpIDs[jump] ?? UUID()
            jumpIDs[jump] = id
            items.append(SSHImportItem(id: id, category: .hosts, name: jump, source: "ProxyJump", host: value))
        }
        // A multi-hop route must not rewrite the standalone configuration of its intermediate aliases.
        for id in originalIDs {
            guard let index = items.firstIndex(where: { $0.id == id }),
                let chain = items[index].host?.jumps, chain.count > 1
            else { continue }
            var previous = chain[0]
            for alias in chain.dropFirst() {
                guard let base = items.first(where: { $0.host?.alias == alias }), var host = base.host else { continue }
                let routeAlias = previous + " → " + alias
                if !items.contains(where: { $0.host?.alias == routeAlias }) {
                    host.alias = routeAlias
                    host.jumps = [previous]
                    let id = jumpIDs[routeAlias] ?? UUID()
                    jumpIDs[routeAlias] = id
                    items.append(
                        SSHImportItem(
                            id: id, category: .hosts, name: routeAlias,
                            source: items[index].source, warnings: base.warnings, host: host))
                }
                previous = routeAlias
            }
            items[index].host?.jumps = [previous]
        }
    }

    func refreshDuplicates() {
        for index in items.indices {
            guard !items[index].unavailable else { continue }
            if let key = items[index].key {
                if let existing = library.keys.first(where: {
                    $0.fingerprint == key.fingerprint && $0.certificate == key.certificate
                        && library.keyAvailability(for: $0) == .available
                }) {
                    items[index].existingID = existing.id
                    items[index].selected = false
                } else if let duplicate = items[..<index].first(where: {
                    $0.key?.fingerprint == key.fingerprint && $0.key?.certificate == key.certificate
                }) {
                    items[index].existingID = duplicate.existingID ?? duplicate.id
                    items[index].selected = false
                }
            }
            if let entry = items[index].knownHost {
                let same: (KnownHostEntry) -> Bool = {
                    $0.hostname == entry.hostname && ($0.isHashed || $0.port == entry.port)
                        && $0.identity == entry.identity
                }
                if let existing = library.knownHosts.first(where: same) {
                    items[index].existingID = existing.id
                    items[index].selected = false
                } else if let previous = items[..<index].first(where: { $0.knownHost.map(same) == true }) {
                    items[index].existingID = previous.existingID ?? previous.id
                    items[index].selected = false
                }
            }
        }
        for index in items.indices where items[index].host != nil {
            if let existing = identicalHost(items[index]) {
                items[index].existingID = existing.id
                items[index].selected = false
            }
        }
    }

    func selectable(_ item: SSHImportItem) -> Bool { !item.unavailable && item.existingID == nil }
    func selectedItems(_ category: SSHImportCategory? = nil) -> [SSHImportItem] {
        items.filter { (category == nil || $0.category == category) && selectable($0) && $0.selected }
    }
    func availableItems(_ category: SSHImportCategory? = nil) -> [SSHImportItem] {
        items.filter { (category == nil || $0.category == category) && selectable($0) }
    }
    func setSelected(_ selected: Bool, category: SSHImportCategory? = nil) {
        for index in items.indices
        where selectable(items[index]) && (category == nil || items[index].category == category) {
            items[index].selected = selected
        }
    }

    func keyOptions(for item: SSHImportItem) -> [SSHKeyRef] {
        guard let host = item.host else { return [] }
        if let id = host.existingKeyID, let key = library.key(id) { return [key] }
        var seen: Set<UUID> = []
        return host.identityPaths.flatMap { path in
            items.filter {
                guard $0.source == path && $0.category == .keys else { return false }
                if host.certificatePaths.isEmpty {
                    return $0.certificatePaths.isEmpty || $0.certificatePaths.contains(path + "-cert.pub")
                }
                return !$0.certificatePaths.isEmpty && !Set($0.certificatePaths).isDisjoint(with: host.certificatePaths)
            }.compactMap { candidate -> SSHKeyRef? in
                if let id = candidate.existingID {
                    if let key = library.key(id) { return key }
                    if let other = items.first(where: { $0.id == id && $0.selected }) { return other.key }
                    return nil
                }
                return candidate.selected ? candidate.key : nil
            }
        }.filter { seen.insert($0.id).inserted }
    }

    func chosenKey(for item: SSHImportItem) -> SSHKeyRef? {
        let options = keyOptions(for: item)
        return options.first { $0.id == item.preferredKeyID } ?? options.first
    }

    private func identicalHost(_ item: SSHImportItem) -> Host? {
        func matches(_ row: SSHImportItem, _ saved: Host, visited: Set<UUID>) -> Bool {
            guard !visited.contains(saved.id), visited.count < 8, let candidate = row.host,
                saved.name == row.name && saved.host == candidate.hostname && saved.port == candidate.port,
                let identity = saved.identityID.flatMap(library.identity), identity.username == candidate.username,
                identity.keyID == chosenKey(for: row)?.id
            else { return false }
            if candidate.jumps.isEmpty { return saved.jumpHostID == nil }
            guard candidate.jumps.count == 1, let alias = candidate.jumps.first,
                let jump = saved.jumpHostID.flatMap(library.host)
            else { return false }
            if let next = items.first(where: { $0.host?.alias == alias }) {
                return matches(next, jump, visited: visited.union([saved.id]))
            }
            return jump.name == alias
        }
        return library.hosts.first { matches(item, $0, visited: []) }
    }

    func warnings(for item: SSHImportItem) -> [String] {
        var warnings = item.warnings
        if let entry = item.knownHost,
            library.knownHosts.contains(where: {
                let sameAddress =
                    $0.hostname == entry.hostname && ($0.isHashed || $0.port == entry.port)
                    || (!entry.isHashed && $0.matches(hostname: entry.hostname, port: entry.port))
                    || (!$0.isHashed && entry.matches(hostname: $0.hostname, port: $0.port))
                return sameAddress && $0.identity != entry.identity
            })
        {
            warnings.append(
                String(localized: "This address already has a different trusted fingerprint. Confirm adding this key."))
        }
        return warnings
    }

    func hasNameConflict(_ item: SSHImportItem) -> Bool {
        guard item.host != nil else { return false }
        return (library.hosts.contains { $0.name == item.name } && identicalHost(item) == nil)
            || selectedItems(.hosts).contains { $0.id != item.id && $0.name == item.name }
    }

    func problem(for item: SSHImportItem, includeWarningReminder: Bool = true) -> String? {
        if !item.issue.isEmpty { return item.issue }
        if item.requiresPassphrase {
            return String(localized: "Enter the key passphrase to validate this private key.")
        }
        if includeWarningReminder && !warnings(for: item).isEmpty && !item.acceptedWarnings {
            return String(localized: "Review and accept the import warnings.")
        }
        if let host = item.host {
            guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !host.hostname.isEmpty, (1...65_535).contains(host.port)
            else { return String(localized: "Invalid SSH record.") }
            if hasNameConflict(item) {
                return String(localized: "A different host already uses this name. Rename this import or deselect it.")
            }
            for jump in host.jumps {
                if !library.hosts.contains(where: { $0.name == jump })
                    && !items.contains(where: { $0.host?.alias == jump && ($0.selected || $0.existingID != nil) })
                {
                    return String(localized: "Select the required jump host or deselect this host.")
                }
            }
        }
        return nil
    }

    var canImport: Bool {
        !isWorking && !completed && !selectedItems().isEmpty
            && selectedItems().allSatisfy { problem(for: $0) == nil }
            && (try? makeBatch()) != nil
    }

    func unlock(_ id: UUID, passphrase: String) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            items[index].key = try await reader.unlock(id: id, name: items[index].name, passphrase: passphrase)
            items[index].requiresPassphrase = false
            items[index].issue = ""
            refreshDuplicates()
        } catch {
            items[index].issue = String(localized: "The key or passphrase is invalid. Retry or deselect this key.")
        }
    }

    func commit() async {
        refreshDuplicates()
        guard canImport else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            var batch = try makeBatch()
            batch.credentials = try await reader.credentials(for: Set(batch.keys.map(\.id)))
            // Revalidate after awaiting the reader, because another window or sync can write meanwhile.
            refreshDuplicates()
            let refreshed = try makeBatch()
            guard Set(refreshed.keys.map(\.id)) == Set(batch.keys.map(\.id)),
                selectedItems().allSatisfy({ problem(for: $0) == nil })
            else {
                throw CocoaError(.validationMultipleErrors)
            }
            batch.hosts = refreshed.hosts
            batch.identities = refreshed.identities
            batch.knownHosts = refreshed.knownHosts
            try library.commitSSHImport(batch)
            importedCount = batch.keys.count + batch.hosts.count + batch.knownHosts.count
            completed = true
            await reader.discard()
        } catch { self.error = error.localizedDescription }
    }

    func discard() async { await reader.discard() }

    private func makeBatch() throws -> SSHImportBatch {
        var batch = SSHImportBatch()
        batch.keys = selectedItems(.keys).compactMap { item in
            guard var key = item.key else { return nil }
            key.storage = storage
            return key
        }
        batch.knownHosts = selectedItems(.knownHosts).compactMap(\.knownHost)
        var built: [UUID: Host] = [:]
        var visiting: Set<UUID> = []
        func build(_ item: SSHImportItem, forcedJump: UUID? = nil) throws -> Host {
            if let existing = item.existingID.flatMap(library.host) { return existing }
            if let existing = built[item.id] {
                if let forcedJump, existing.jumpHostID != forcedJump { throw ImportRouteError.conflictingChain }
                return existing
            }
            guard visiting.insert(item.id).inserted, visiting.count <= 8, let imported = item.host else {
                throw ImportRouteError.invalid
            }
            defer { visiting.remove(item.id) }
            var jumpID = forcedJump
            for alias in imported.jumps {
                if let candidate = items.first(where: {
                    $0.host?.alias == alias && ($0.selected || $0.existingID != nil)
                }) {
                    jumpID = try build(candidate, forcedJump: jumpID).id
                } else if let existing = library.hosts.first(where: { $0.name == alias }) {
                    if let jumpID, existing.jumpHostID != jumpID { throw ImportRouteError.conflictingChain }
                    jumpID = existing.id
                } else {
                    throw ImportRouteError.invalid
                }
            }
            let keyID = chosenKey(for: item)?.id
            let identity: Identity
            if let existing = (library.identities + batch.identities).first(where: {
                $0.username == imported.username && $0.keyID == keyID
            }) {
                identity = existing
            } else {
                identity = Identity(name: imported.username, username: imported.username, keyID: keyID)
                batch.identities.append(identity)
            }
            let host = Host(
                id: item.id, name: item.name, host: imported.hostname, port: imported.port,
                identityID: identity.id, jumpHostID: jumpID)
            built[item.id] = host
            return host
        }
        // Build routes with the most hops first so intermediate aliases get their chain before reuse.
        for item in selectedItems(.hosts).sorted(by: { ($0.host?.jumps.count ?? 0) > ($1.host?.jumps.count ?? 0) }) {
            _ = try build(item)
        }
        batch.hosts = built.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let all = Dictionary(uniqueKeysWithValues: (library.hosts + batch.hosts).map { ($0.id, $0) })
        for host in batch.hosts {
            var current: Host? = host
            var seen: Set<UUID> = []
            while let node = current {
                guard seen.insert(node.id).inserted, seen.count <= 8 else { throw ImportRouteError.invalid }
                current = node.jumpHostID.flatMap { all[$0] }
            }
        }
        return batch
    }

    var routeProblem: String? {
        do {
            _ = try makeBatch()
            return nil
        } catch { return error.localizedDescription }
    }
}

nonisolated private enum ImportRouteError: LocalizedError {
    case invalid, conflictingChain
    var errorDescription: String? {
        switch self {
        case .invalid: String(localized: "The imported jump route is missing, cyclic, or exceeds 8 hops.")
        case .conflictingChain:
            String(localized: "These hosts require conflicting jump routes. Import the routes separately.")
        }
    }
}
