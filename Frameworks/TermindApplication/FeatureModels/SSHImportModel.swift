import Foundation
import TermindDomain

import struct TermindDomain.Host

@Observable
public final class SSHImportModel {
    public var items: [SSHImportItem] = []
    public var expanded = Set(SSHImportCategory.allCases)
    public var storage: PasswordStorage
    public var importColor: TagColor = .none
    public var hostGroupID: HostGroup.ID?
    public var hostTags: [String] = []
    public private(set) var isWorking = false
    public private(set) var error: String?
    public private(set) var completed = false
    public private(set) var importedCount = 0
    private let library: HostLibraryModel
    private let reader: any SSHImportReading
    private var root: URL?
    private var grants: [URL] = []
    public var sourcePath: String? { root?.path }
    private var knownHostsOnly = false
    private let defaultUsername: String
    private var jumpIDs: [String: UUID] = [:]
    private var stableIdentityIDs: [IdentitySignature: UUID] = [:]
    private var itemIndexByID: [UUID: Int] = [:]
    private var keyOptionsByHostID: [UUID: [SSHKeyRef]] = [:]
    private var keyItemIDByKeyID: [UUID: UUID] = [:]
    private var hostIDsByIdentityID: [UUID: [UUID]] = [:]
    private var selectedHostNameCounts: [String: Int] = [:]
    private var existingHostNames: Set<String> = []

    private struct IdentitySignature: Hashable {
        var username: String
        var keyID: UUID?
    }

    public init(
        library: HostLibraryModel,
        reader: any SSHImportReading,
        defaultUsername: String = "",
        storage: PasswordStorage = .iCloud
    ) {
        self.defaultUsername = defaultUsername
        self.library = library
        self.reader = reader
        self.storage = storage
    }

    public func scan(_ url: URL, knownHostsOnly: Bool) async {
        guard !isWorking else { return }
        grants = []
        items = []
        completed = false
        root = url
        self.knownHostsOnly = knownHostsOnly
        await reload()
    }

    public func authorize(_ url: URL) async {
        grants.append(url)
        await reload()
    }

    private func reload() async {
        guard let root else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let previousItems = items
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
            rebuildIdentityPlan(preserving: previousItems)
        } catch {
            self.error =
                (error as? SSHImportSourceError)?.localizedDescription
                ?? String(localized: "The SSH files could not be read.")
        }
    }

    private func addJumpDestinations() {
        let originalIndexes = items.indices.filter { items[$0].host != nil }
        var itemIndexByAlias: [String: Int] = [:]
        for index in originalIndexes {
            if let alias = items[index].host?.alias { itemIndexByAlias[alias] = index }
        }
        let savedHostsByName = Dictionary(
            library.hosts.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let jumps = items.compactMap(\.host).flatMap(\.jumps)
        for jump in jumps where itemIndexByAlias[jump] == nil {
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
            let saved = savedHostsByName[host]
            let identity = saved?.identityID.flatMap(library.identity)
            let base = itemIndexByAlias[host].flatMap { items[$0].host }
            let value = SSHImportedHost(
                alias: jump, hostname: base?.hostname ?? saved?.host ?? host,
                port: port ?? base?.port ?? saved?.port ?? 22,
                username: userParts.count == 2 ? userParts[0] : base?.username ?? identity?.username ?? defaultUsername,
                identityPaths: base?.identityPaths ?? [], existingKeyID: identity?.keyID)
            let id = jumpIDs[jump] ?? UUID()
            jumpIDs[jump] = id
            items.append(SSHImportItem(id: id, category: .hosts, name: jump, source: "ProxyJump", host: value))
            itemIndexByAlias[jump] = items.index(before: items.endIndex)
        }
        // A multi-hop route must not rewrite the standalone configuration of its intermediate aliases.
        for index in originalIndexes {
            guard let chain = items[index].host?.jumps, chain.count > 1 else { continue }
            var previous = chain[0]
            for alias in chain.dropFirst() {
                guard let baseIndex = itemIndexByAlias[alias], var host = items[baseIndex].host else { continue }
                let routeAlias = previous + " → " + alias
                if itemIndexByAlias[routeAlias] == nil {
                    host.alias = routeAlias
                    host.jumps = [previous]
                    let id = jumpIDs[routeAlias] ?? UUID()
                    jumpIDs[routeAlias] = id
                    items.append(
                        SSHImportItem(
                            id: id, category: .hosts, name: routeAlias,
                            source: items[index].source, warnings: items[baseIndex].warnings, host: host))
                    itemIndexByAlias[routeAlias] = items.index(before: items.endIndex)
                }
                previous = routeAlias
            }
            items[index].host?.jumps = [previous]
        }
    }

    public func refreshDuplicates() {
        for index in items.indices where items[index].category != .identities {
            items[index].existingID = nil
        }
        rebuildItemIndex()
        rebuildKeyOptionIndex()
        let existingKeys = Dictionary(
            library.keys.compactMap { key in
                library.keyAvailability(for: key) == .available
                    ? (KeySignature(fingerprint: key.fingerprint, certificate: key.certificate), key.id) : nil
            }, uniquingKeysWith: { first, _ in first })
        var seenKeys: [KeySignature: UUID] = [:]
        var existingKnownHosts: [KnownHostSignature: UUID] = [:]
        for entry in library.knownHosts {
            existingKnownHosts[KnownHostSignature(entry), default: entry.id] = entry.id
        }
        var seenKnownHosts: [KnownHostSignature: UUID] = [:]
        for index in items.indices {
            guard !items[index].unavailable else { continue }
            if let key = items[index].key {
                let signature = KeySignature(fingerprint: key.fingerprint, certificate: key.certificate)
                if let existingID = existingKeys[signature] {
                    items[index].existingID = existingID
                    items[index].selected = false
                } else if let duplicateID = seenKeys[signature] {
                    items[index].existingID = duplicateID
                    items[index].selected = false
                }
                seenKeys[signature] = items[index].existingID ?? items[index].id
            }
            if let entry = items[index].knownHost {
                let signature = KnownHostSignature(entry)
                if let existingID = existingKnownHosts[signature] {
                    items[index].existingID = existingID
                    items[index].selected = false
                } else if let duplicateID = seenKnownHosts[signature] {
                    items[index].existingID = duplicateID
                    items[index].selected = false
                }
                seenKnownHosts[signature] = items[index].existingID ?? items[index].id
            }
        }
        for index in items.indices where items[index].host != nil {
            if let existing = identicalHost(items[index]) {
                items[index].existingID = existing.id
                items[index].selected = false
            }
        }
        rebuildItemIndex()
    }

    public func selectable(_ item: SSHImportItem) -> Bool { !item.unavailable && item.existingID == nil }
    public func selectedItems(_ category: SSHImportCategory? = nil) -> [SSHImportItem] {
        items.filter { (category == nil || $0.category == category) && selectable($0) && $0.selected }
    }
    public func availableItems(_ category: SSHImportCategory? = nil) -> [SSHImportItem] {
        items.filter { (category == nil || $0.category == category) && selectable($0) }
    }
    public func setSelected(_ selected: Bool, category: SSHImportCategory? = nil) {
        var changedIdentities: Set<UUID> = []
        var deselectedKeyIDs: Set<UUID> = []
        for index in items.indices
        where selectable(items[index]) && (category == nil || items[index].category == category) {
            items[index].selected = selected
            if items[index].category == .identities { changedIdentities.insert(items[index].id) }
            if !selected, let key = items[index].key { deselectedKeyIDs.insert(key.id) }
        }
        applyIdentityKeyDependencies(selected: selected, identityIDs: changedIdentities)
        if !deselectedKeyIDs.isEmpty {
            changedIdentities.formUnion(deselectIdentities(using: deselectedKeyIDs))
        }
        rebuildHostNameIndex()
        updateHostBindings(for: changedIdentities)
    }

    public func setSelected(_ selected: Bool, itemID: UUID) {
        guard let index = itemIndexByID[itemID], selectable(items[index]) else { return }
        let category = items[index].category
        let wasSelected = items[index].selected
        items[index].selected = selected
        if category == .hosts, wasSelected != selected {
            selectedHostNameCounts[items[index].name, default: 0] += selected ? 1 : -1
        }
        var changedIdentities: Set<UUID> = category == .identities ? [itemID] : []
        if category == .identities, selected {
            applyIdentityKeyDependencies(selected: true, identityIDs: changedIdentities)
        } else if category == .keys, !selected, let keyID = items[index].key?.id {
            changedIdentities.formUnion(deselectIdentities(using: [keyID]))
        }
        updateHostBindings(for: changedIdentities)
    }

    public func isSelected(_ itemID: UUID) -> Bool {
        itemIndexByID[itemID].map { items[$0].selected } ?? false
    }

    public func item(_ itemID: UUID) -> SSHImportItem? {
        itemIndexByID[itemID].map { items[$0] }
    }

    public func updateItem(_ updated: SSHImportItem) {
        guard let initialIndex = itemIndexByID[updated.id] else { return }
        let current = items[initialIndex]
        if current.selected != updated.selected { setSelected(updated.selected, itemID: updated.id) }
        if current.preferredKeyID != updated.preferredKeyID {
            setPreferredKey(updated.preferredKeyID, for: updated.id)
        }
        if current.name != updated.name { setName(updated.name, for: updated.id) }
        guard let finalIndex = itemIndexByID[updated.id] else { return }
        items[finalIndex].acceptedWarnings = updated.acceptedWarnings
    }

    public func keyOptions(for item: SSHImportItem) -> [SSHKeyRef] {
        if let cached = keyOptionsByHostID[item.id] { return cached }
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
                return candidate.key
            }
        }.filter { seen.insert($0.id).inserted }
    }

    public func chosenKey(for item: SSHImportItem) -> SSHKeyRef? {
        let options = keyOptions(for: item)
        return options.first { $0.id == item.preferredKeyID } ?? options.first
    }

    public func setPreferredKey(_ keyID: UUID?, for hostID: UUID) {
        guard let index = itemIndexByID[hostID], items[index].host != nil else { return }
        let previousItems = items
        items[index].preferredKeyID = keyID
        rebuildIdentityPlan(preserving: previousItems, changedHostID: hostID)
    }

    public func setName(_ name: String, for itemID: UUID) {
        guard let index = itemIndexByID[itemID] else { return }
        if items[index].category == .hosts, items[index].selected, selectable(items[index]) {
            selectedHostNameCounts[items[index].name, default: 0] -= 1
            selectedHostNameCounts[name, default: 0] += 1
        }
        items[index].name = name
    }

    public func identityName(for hostItem: SSHImportItem) -> String? {
        guard let identityID = hostItem.host?.identityID else { return nil }
        if let index = itemIndexByID[identityID], items[index].identity != nil {
            return items[index].name
        }
        return library.identity(identityID)?.name
    }

    public func linkedHostNames(for identityItem: SSHImportItem) -> [String] {
        (hostIDsByIdentityID[identityItem.id] ?? []).compactMap { id in
            itemIndexByID[id].map { items[$0].name }
        }
    }

    public func keyName(_ id: UUID) -> String? {
        library.key(id)?.label
            ?? keyItemIDByKeyID[id].flatMap { itemIndexByID[$0] }.flatMap { items[$0].key?.label }
    }

    private struct KeySignature: Hashable {
        var fingerprint: String
        var certificate: String
    }

    private struct KnownHostSignature: Hashable {
        var hostname: String
        var port: Int
        var identity: SSHHostKeyIdentity

        init(_ entry: KnownHostEntry) {
            hostname = entry.hostname
            port = entry.isHashed ? 0 : entry.port
            identity = entry.identity
        }
    }

    /// Rebuilds public Identity previews from public key metadata. This never
    /// reads private material. Dictionaries keep the scan linear in items plus
    /// Host-to-key relationships instead of repeating array searches per row.
    private func rebuildIdentityPlan(preserving previousItems: [SSHImportItem], changedHostID: UUID? = nil) {
        let previousIdentities = Dictionary(
            previousItems.compactMap { item -> (IdentitySignature, SSHImportItem)? in
                guard let identity = item.identity else { return nil }
                return (IdentitySignature(username: identity.username, keyID: identity.keyID), item)
            }, uniquingKeysWith: { first, _ in first })
        let previousHostIdentitySelection: Bool? = changedHostID.flatMap { hostID in
            guard let oldHost = previousItems.first(where: { $0.id == hostID }),
                let identityID = oldHost.host?.identityID,
                let identityItem = previousItems.first(where: { $0.id == identityID })
            else { return nil }
            return identityItem.existingID != nil || identityItem.selected
        }

        items.removeAll { $0.category == .identities }
        rebuildItemIndex()
        rebuildKeyOptionIndex()

        let existingIdentities = Dictionary(
            library.reusableIdentities.map {
                (IdentitySignature(username: $0.username, keyID: $0.keyID), $0)
            }, uniquingKeysWith: { first, _ in first })

        var signatures: [IdentitySignature] = []
        var hostsBySignature: [IdentitySignature: [UUID]] = [:]
        for item in items where item.host != nil {
            guard let host = item.host else { continue }
            let signature = IdentitySignature(username: host.username, keyID: chosenKey(for: item)?.id)
            if hostsBySignature[signature] == nil { signatures.append(signature) }
            hostsBySignature[signature, default: []].append(item.id)
        }

        let signaturesPerUsername = Dictionary(grouping: signatures, by: \.username)
        var usedNames: Set<String> = Set(library.reusableIdentities.map(\.name))
        var identityItems: [SSHImportItem] = []
        identityItems.reserveCapacity(signatures.count)
        hostIDsByIdentityID = [:]

        for signature in signatures {
            let hostIDs = hostsBySignature[signature] ?? []
            if let existing = existingIdentities[signature] {
                identityItems.append(
                    SSHImportItem(
                        id: existing.id, category: .identities, name: existing.name,
                        source: identitySource(for: hostIDs), selected: false,
                        identity: existing, existingID: existing.id))
                hostIDsByIdentityID[existing.id] = hostIDs
                continue
            }

            let id = stableIdentityIDs[signature] ?? UUID()
            stableIdentityIDs[signature] = id
            let previous = previousIdentities[signature]
            var name =
                previous?.name
                ?? defaultIdentityName(
                    for: signature,
                    hasAmbiguousUsername: (signaturesPerUsername[signature.username]?.count ?? 0) > 1,
                    usedNames: usedNames)
            if name.isEmpty { name = signature.username }
            usedNames.insert(name)
            let identity = Identity(
                id: id, name: name, username: signature.username,
                passwordStorage: storage, keyID: signature.keyID,
                colorTag: importColor)
            let selected: Bool
            if let previous {
                selected = previous.selected
            } else if let changedHostID, hostIDs.contains(changedHostID), let previousHostIdentitySelection {
                selected = previousHostIdentitySelection
            } else {
                selected = true
            }
            identityItems.append(
                SSHImportItem(
                    id: id, category: .identities, name: name,
                    source: identitySource(for: hostIDs), selected: selected, identity: identity))
            hostIDsByIdentityID[id] = hostIDs
        }

        items.append(contentsOf: identityItems)
        rebuildItemIndex()
        updateAllHostBindings()
    }

    private func rebuildKeyOptionIndex() {
        keyOptionsByHostID = [:]
        keyItemIDByKeyID = [:]
        var canonicalKeysBySignature: [KeySignature: SSHKeyRef] = [:]
        for key in library.keys where library.keyAvailability(for: key) == .available {
            canonicalKeysBySignature[KeySignature(fingerprint: key.fingerprint, certificate: key.certificate)] = key
        }
        for item in items where item.category == .keys {
            guard let key = item.key else { continue }
            let signature = KeySignature(fingerprint: key.fingerprint, certificate: key.certificate)
            if canonicalKeysBySignature[signature] == nil { canonicalKeysBySignature[signature] = key }
        }

        var keyRowsBySource: [String: [(SSHImportItem, SSHKeyRef)]] = [:]
        for item in items where item.category == .keys {
            guard let key = item.key,
                let canonical = canonicalKeysBySignature[
                    KeySignature(fingerprint: key.fingerprint, certificate: key.certificate)]
            else { continue }
            keyRowsBySource[item.source, default: []].append((item, canonical))
            if library.key(canonical.id) == nil { keyItemIDByKeyID[canonical.id] = canonical.id }
        }

        for item in items where item.host != nil {
            guard let host = item.host else { continue }
            if let keyID = host.existingKeyID, let key = library.key(keyID) {
                keyOptionsByHostID[item.id] = [key]
                continue
            }
            var seen: Set<UUID> = []
            var options: [SSHKeyRef] = []
            for path in host.identityPaths {
                for (candidate, key) in keyRowsBySource[path] ?? [] {
                    let matchesCertificate: Bool
                    if host.certificatePaths.isEmpty {
                        matchesCertificate =
                            candidate.certificatePaths.isEmpty
                            || candidate.certificatePaths.contains(path + "-cert.pub")
                    } else {
                        matchesCertificate =
                            !candidate.certificatePaths.isEmpty
                            && !Set(candidate.certificatePaths).isDisjoint(with: host.certificatePaths)
                    }
                    if matchesCertificate, seen.insert(key.id).inserted { options.append(key) }
                }
            }
            keyOptionsByHostID[item.id] = options
        }
    }

    private func defaultIdentityName(
        for signature: IdentitySignature, hasAmbiguousUsername: Bool, usedNames: Set<String>
    ) -> String {
        guard hasAmbiguousUsername || usedNames.contains(signature.username) else { return signature.username }
        let keyLabel =
            signature.keyID.flatMap { keyID in
                library.key(keyID)?.label
                    ?? keyItemIDByKeyID[keyID].flatMap { itemIndexByID[$0] }.flatMap { items[$0].key?.label }
            } ?? String(localized: "No Key")
        let base = "\(signature.username) (\(keyLabel))"
        guard usedNames.contains(base), let keyID = signature.keyID,
            let key = library.key(keyID)
                ?? keyItemIDByKeyID[keyID].flatMap({ itemIndexByID[$0] }).flatMap({ items[$0].key })
        else { return base }
        let shortFingerprint = key.fingerprint.split(separator: ":").last.map(String.init)?.prefix(8) ?? ""
        return "\(base) \(shortFingerprint)"
    }

    private func identitySource(for hostIDs: [UUID]) -> String {
        hostIDs.compactMap { id in itemIndexByID[id].map { items[$0].name } }.joined(separator: ", ")
    }

    private func rebuildItemIndex() {
        itemIndexByID = Dictionary(uniqueKeysWithValues: items.indices.map { (items[$0].id, $0) })
        rebuildHostNameIndex()
    }

    private func rebuildHostNameIndex() {
        existingHostNames = Set(library.hosts.map(\.name))
        selectedHostNameCounts = [:]
        for item in items where item.host != nil && item.selected && selectable(item) {
            selectedHostNameCounts[item.name, default: 0] += 1
        }
    }

    private func applyIdentityKeyDependencies(selected: Bool, identityIDs: Set<UUID>) {
        guard selected else { return }
        for identityID in identityIDs {
            guard let identityIndex = itemIndexByID[identityID], let keyID = items[identityIndex].identity?.keyID,
                let keyItemID = keyItemIDByKeyID[keyID], let keyIndex = itemIndexByID[keyItemID],
                selectable(items[keyIndex])
            else { continue }
            items[keyIndex].selected = true
        }
    }

    private func deselectIdentities(using keyIDs: Set<UUID>) -> Set<UUID> {
        var changed: Set<UUID> = []
        for index in items.indices where items[index].category == .identities && items[index].existingID == nil {
            guard let keyID = items[index].identity?.keyID, keyIDs.contains(keyID), items[index].selected else {
                continue
            }
            items[index].selected = false
            changed.insert(items[index].id)
        }
        return changed
    }

    private func updateAllHostBindings() {
        for identityID in hostIDsByIdentityID.keys { updateHostBindings(for: [identityID]) }
    }

    private func updateHostBindings(for identityIDs: Set<UUID>) {
        for identityID in identityIDs {
            guard let identityIndex = itemIndexByID[identityID] else { continue }
            let identityItem = items[identityIndex]
            let keyAvailable =
                identityItem.identity?.keyID.map { keyID in
                    library.key(keyID) != nil
                        || keyItemIDByKeyID[keyID].flatMap { itemIndexByID[$0] }.map { items[$0].selected } == true
                } ?? true
            let available = identityItem.existingID != nil || (identityItem.selected && keyAvailable)
            for hostID in hostIDsByIdentityID[identityID] ?? [] {
                guard let hostIndex = itemIndexByID[hostID] else { continue }
                items[hostIndex].host?.identityID = available ? identityID : nil
            }
        }
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

    public func warnings(for item: SSHImportItem) -> [String] {
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

    public func hasNameConflict(_ item: SSHImportItem) -> Bool {
        guard item.host != nil else { return false }
        return (existingHostNames.contains(item.name) && item.existingID == nil)
            || selectedHostNameCounts[item.name, default: 0] > 1
    }

    public func problem(for item: SSHImportItem, includeWarningReminder: Bool = true) -> String? {
        if !item.issue.isEmpty { return item.issue }
        if item.requiresPassphrase {
            return String(localized: "Enter the key passphrase to validate this private key.")
        }
        if includeWarningReminder && !warnings(for: item).isEmpty && !item.acceptedWarnings {
            return String(localized: "Review and accept the import warnings.")
        }
        if let identity = item.identity {
            guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !identity.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return String(localized: "Invalid SSH record.") }
            if let keyID = identity.keyID, library.key(keyID) == nil,
                keyItemIDByKeyID[keyID].flatMap({ itemIndexByID[$0] }).map({ items[$0].selected }) != true
            {
                return String(localized: "Invalid SSH record.")
            }
        }
        if let host = item.host {
            guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !host.hostname.isEmpty, !host.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                (1...65_535).contains(host.port)
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

    public var canImport: Bool {
        !isWorking && !completed && !selectedItems().isEmpty
            && selectedItems().allSatisfy { problem(for: $0) == nil }
            && (try? makeBatch()) != nil
    }

    public func unlock(_ id: UUID, passphrase: String) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let previous = items[index]
            var replacements = try await reader.unlock(id: id, name: previous.name, passphrase: passphrase)
            guard !replacements.isEmpty, replacements.allSatisfy({ $0.category == .keys && $0.key != nil }) else {
                throw CocoaError(.coderInvalidValue)
            }
            for replacementIndex in replacements.indices {
                replacements[replacementIndex].selected = previous.selected
                replacements[replacementIndex].acceptedWarnings = previous.acceptedWarnings
            }
            items.replaceSubrange(index...index, with: replacements)
            refreshDuplicates()
            rebuildIdentityPlan(preserving: items)
        } catch {
            if let sourceError = error as? SSHImportSourceError {
                self.error = sourceError.localizedDescription
            } else {
                items[index].issue = String(localized: "The key or passphrase is invalid. Retry or deselect this key.")
            }
        }
    }

    public func commit() async {
        let beforeInitialRefresh = items
        refreshDuplicates()
        rebuildIdentityPlan(preserving: beforeInitialRefresh)
        guard canImport else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            var batch = try makeBatch()
            try await library.resolveSavingHostsAccess(batch.hosts)
            batch.credentials = try await reader.credentials(for: Set(batch.keys.map(\.id)))
            // Revalidate after awaiting the reader, because another window or sync can write meanwhile.
            let beforeFinalRefresh = items
            refreshDuplicates()
            rebuildIdentityPlan(preserving: beforeFinalRefresh)
            let refreshed = try makeBatch()
            guard Set(refreshed.keys.map(\.id)) == Set(batch.keys.map(\.id)),
                selectedItems().allSatisfy({ problem(for: $0) == nil })
            else {
                throw CocoaError(.coderInvalidValue)
            }
            batch.hosts = refreshed.hosts
            batch.identities = refreshed.identities
            batch.knownHosts = refreshed.knownHosts
            try library.commitSSHImport(batch)
            importedCount = batch.keys.count + batch.identities.count + batch.hosts.count + batch.knownHosts.count
            completed = true
            await reader.discard()
        } catch HostAccessError.hostLimit {
            // The host quota presents the Paywall without replacing the import selection with an error.
            self.error = nil
        } catch { self.error = error.localizedDescription }
    }

    public func discard() async { await reader.discard() }

    private func makeBatch() throws -> SSHImportBatch {
        var batch = SSHImportBatch()
        batch.keys = selectedItems(.keys).compactMap { item in
            guard var key = item.key else { return nil }
            key.storage =
                switch storage {
                case .thisDevice: .thisDevice
                case .iCloud: .iCloud
                }
            key.colorTag = importColor
            return key
        }
        batch.knownHosts = selectedItems(.knownHosts).compactMap(\.knownHost)
        let selectedKeyIDs = Set(batch.keys.map(\.id))
        batch.identities = selectedItems(.identities).compactMap { item in
            guard var identity = item.identity,
                identity.keyID.map({ library.key($0) != nil || selectedKeyIDs.contains($0) }) ?? true
            else { return nil }
            identity.name = item.name
            identity.passwordStorage = storage
            identity.colorTag = importColor
            return identity
        }
        let importedIdentityIDs = Set(batch.identities.map(\.id))
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
            let identityID = imported.identityID.flatMap { id in
                library.identity(id) != nil || importedIdentityIDs.contains(id) ? id : nil
            }
            let host = Host(
                id: item.id, name: item.name, host: imported.hostname, port: imported.port,
                identityID: identityID, jumpHostID: jumpID, groupID: hostGroupID,
                tags: hostTags, colorTag: importColor)
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

    public var routeProblem: String? {
        do {
            _ = try makeBatch()
            return nil
        } catch { return error.localizedDescription }
    }
}

nonisolated private enum ImportRouteError: LocalizedError {
    case invalid, conflictingChain
    public var errorDescription: String? {
        switch self {
        case .invalid: String(localized: "The imported jump route is missing, cyclic, or exceeds 8 hops.")
        case .conflictingChain:
            String(localized: "These hosts require conflicting jump routes. Import the routes separately.")
        }
    }
}
