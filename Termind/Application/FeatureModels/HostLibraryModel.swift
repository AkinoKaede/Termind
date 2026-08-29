import Foundation

/// The single source of truth for saved hosts, groups, keys, snippets, and port
/// forwarding rules.
///
/// Core host metadata is backed by SwiftData in the app and projected into value
/// types for the views. Previews can still construct an in-memory store directly.
@Observable
final class HostLibraryModel {
    private(set) var hosts: [Host] = []
    private(set) var groups: [HostGroup] = []
    private(set) var keys: [SSHKeyRef] = []
    private(set) var identities: [Identity] = []
    private(set) var snippets: [Snippet] = []
    private(set) var snippetPackages: [SnippetPackage] = []
    private(set) var portForwardings: [PortForwardingRule] = []
    private(set) var sftpTransfers: [SFTPTransfer] = []
    private(set) var knownHosts: [KnownHostEntry] = []

    /// The latest local persistence failure. Secret text is never included.
    private(set) var storageError: String?
    private let vault: VaultStore
    private let keychain: any SecretStoring
    /// Runtime resources live in AppModel, so deletion announces before model
    /// references are removed and the controller can stop listeners cleanly.
    var willDeleteHost: ((Host.ID, [PortForwardingRule.ID]) -> Void)?
    var willDeletePortForwardings: (([PortForwardingRule.ID]) -> Void)?
    var didPersistCore: (() -> Void)? {
        get { vault.didPersist }
        set { vault.didPersist = newValue }
    }
    var didRecordVaultChanges: ((VaultMutationSet) -> Void)? {
        get { vault.didRecordChanges }
        set { vault.didRecordChanges = newValue }
    }

    func reportStorageError(_ error: any Error) {
        storageError = error.localizedDescription
    }

    /// Live connection state, keyed by host. Lives here rather than on `Host`
    /// because it is session state, not user data — it must never be persisted
    /// or synced.
    private(set) var statuses: [Host.ID: ConnectionStatus] = [:]
    private var connectionStatuses: [UUID: (hostID: Host.ID, status: ConnectionStatus)] = [:]

    /// Whether the Hosts page's Ungrouped section is open.
    ///
    /// Lives here rather than as view state because a real group keeps its
    /// `isExpanded` on the model: if this were a `@State` on the page, folding
    /// Ungrouped would spring back open on the next rebuild while folding
    /// Production stayed folded, and there would be no way to explain the
    /// difference to whoever noticed.
    private(set) var isUngroupedExpanded = true
    private(set) var isSnippetsUngroupedExpanded = true

    init(
        hosts: [Host] = [],
        groups: [HostGroup] = [],
        keys: [SSHKeyRef] = [],
        identities: [Identity] = [],
        snippets: [Snippet] = [],
        snippetPackages: [SnippetPackage] = [],
        portForwardings: [PortForwardingRule] = [],
        sftpTransfers: [SFTPTransfer] = [],
        knownHosts: [KnownHostEntry] = [],
        persistence: (any VaultPersisting)? = nil,
        secrets: any SecretStoring = InMemorySecretStore()
    ) {
        self.hosts = hosts
        self.groups = groups
        self.keys = normalizedManualOrder(
            keys, sortIndex: \SSHKeyRef.sortIndex, name: \SSHKeyRef.label
        )
        self.identities = normalizedManualOrder(
            identities, sortIndex: \Identity.sortIndex, name: \Identity.name
        )
        self.snippets = normalizedSnippetOrder(snippets)
        self.snippetPackages = snippetPackages
        self.portForwardings = portForwardings
        self.sftpTransfers = sftpTransfers
        self.knownHosts = knownHosts
        self.vault = VaultStore(persistence: persistence)
        self.keychain = secrets
        do {
            let loaded = try vault.load(
                fallback: VaultSnapshot(
                    hosts: hosts, groups: groups, identities: identities, keys: keys,
                    knownHosts: knownHosts, snippets: snippets,
                    snippetPackages: snippetPackages, portForwardings: portForwardings
                )
            )
            self.hosts = loaded.hosts
            self.groups = loaded.groups
            self.identities = loaded.identities.sorted {
                manuallyOrdered($0.sortIndex, $0.name, $1.sortIndex, $1.name)
            }
            self.keys = loaded.keys.sorted {
                manuallyOrdered($0.sortIndex, $0.label, $1.sortIndex, $1.label)
            }
            self.knownHosts = loaded.knownHosts
            self.snippets = loaded.snippets.sorted { $0.sortIndex < $1.sortIndex }
            self.snippetPackages = loaded.snippetPackages
            self.portForwardings = loaded.portForwardings
        } catch {
            storageError = error.localizedDescription
        }
    }

    // MARK: - Reads

    func host(_ id: Host.ID) -> Host? {
        hosts.first { $0.id == id }
    }

    func group(_ id: HostGroup.ID) -> HostGroup? {
        groups.first { $0.id == id }
    }

    func snippet(_ id: Snippet.ID) -> Snippet? {
        snippets.first { $0.id == id }
    }

    func snippetPackage(_ id: SnippetPackage.ID) -> SnippetPackage? {
        snippetPackages.first { $0.id == id }
    }

    var rootSnippetPackages: [SnippetPackage] {
        snippetPackages.filter { $0.parentID == nil }.sorted { $0.sortIndex < $1.sortIndex }
    }

    func childSnippetPackages(of parent: SnippetPackage.ID) -> [SnippetPackage] {
        snippetPackages.filter { $0.parentID == parent }.sorted { $0.sortIndex < $1.sortIndex }
    }

    func descendantSnippetPackages(of parent: SnippetPackage.ID) -> [SnippetPackage] {
        childSnippetPackages(of: parent).flatMap {
            [$0] + descendantSnippetPackages(of: $0.id)
        }
    }

    func snippets(in package: SnippetPackage.ID?) -> [Snippet] {
        snippets.filter { $0.packageID == package }.sorted { $0.sortIndex < $1.sortIndex }
    }

    func snippetPackagePath(_ packageID: SnippetPackage.ID?) -> String? {
        guard let packageID, let package = snippetPackage(packageID) else { return nil }
        var names = [package.name]
        var parentID = package.parentID
        var visited: Set<SnippetPackage.ID> = [package.id]
        while let id = parentID, let parent = snippetPackage(id), visited.insert(id).inserted {
            names.append(parent.name)
            parentID = parent.parentID
        }
        return names.reversed().joined(separator: " / ")
    }

    func status(of id: Host.ID) -> ConnectionStatus {
        if statuses[id] == .connected { return .connected }
        if sftpTransfers.contains(where: {
            $0.involves(id) && $0.state == .running
        }) {
            return .connected
        }
        if let status = statuses[id] { return status }
        if sftpTransfers.contains(where: {
            $0.involves(id) && $0.state == .queued
        }) {
            return .connecting
        }
        return .disconnected
    }

    /// Top-level groups, in sort order.
    var rootGroups: [HostGroup] {
        groups.filter { $0.parentID == nil }.sorted { $0.sortIndex < $1.sortIndex }
    }

    func childGroups(of parent: HostGroup.ID) -> [HostGroup] {
        groups.filter { $0.parentID == parent }.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Every group below `parent`, at any depth, parents before children.
    ///
    /// What a delete has to take with it, and — read the other way — the set a
    /// group may *not* be re-filed into, since a group cannot become its own
    /// descendant.
    func descendantGroups(of parent: HostGroup.ID) -> [HostGroup] {
        childGroups(of: parent).flatMap { [$0] + descendantGroups(of: $0.id) }
    }

    /// Hosts directly inside a group — `nil` means "not filed in any group".
    func hosts(in group: HostGroup.ID?) -> [Host] {
        hosts.filter { $0.groupID == group }.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Hosts anywhere in a group's subtree. The number a delete has to warn
    /// about: deleting Production takes Edge with it, so the machines filed in
    /// Edge are just as much at stake as the ones filed in Production.
    func hosts(inTreeOf group: HostGroup.ID) -> [Host] {
        let tree = Set([group] + descendantGroups(of: group).map(\.id))
        return hosts.filter { host in host.groupID.map(tree.contains) ?? false }
    }

    func portForwardings(for host: Host.ID) -> [PortForwardingRule] {
        portForwardings.filter { $0.hostID == host }
    }

    func portForwarding(_ id: PortForwardingRule.ID) -> PortForwardingRule? {
        portForwardings.first { $0.id == id }
    }

    func sftpTransfers(for host: Host.ID) -> [SFTPTransfer] {
        sftpTransfers.filter { $0.involves(host) }
    }

    func key(_ id: SSHKeyRef.ID) -> SSHKeyRef? {
        keys.first { $0.id == id }
    }

    func identity(_ id: Identity.ID) -> Identity? {
        identities.first { $0.id == id }
    }

    /// The login a host connects with, resolved through the store so renaming an
    /// identity renames it everywhere it is shown.
    func identity(for host: Host) -> Identity? {
        host.identityID.flatMap { identity($0) }
    }

    /// `user@host:port` — what the UI shows almost everywhere a host is named.
    ///
    /// Falls back to the bare address when no identity is set, rather than
    /// inventing a login: a host that does not yet know who it connects as
    /// should look like one.
    func loginAddress(for host: Host) -> String {
        guard let username = identity(for: host)?.username, !username.isEmpty else {
            return host.displayAddress
        }
        return "\(username)@\(host.displayAddress)"
    }

    /// Which identities would break if a key were deleted. The Keys list shows
    /// this count, because "delete" needs to say what it takes with it.
    func identities(using key: SSHKeyRef.ID) -> [Identity] {
        identities.filter { $0.keyID == key }
    }

    /// The pinned host keys for a saved host, matched the way OpenSSH matches:
    /// hostname plus port. Newest keys are shown first in the host's details.
    func knownHosts(for host: Host) -> [KnownHostEntry] {
        knownHosts
            .filter { $0.hostname == host.host && $0.port == host.port }
            .sorted {
                if $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
                if $0.fingerprint != $1.fingerprint { return $0.fingerprint < $1.fingerprint }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    /// Resolves persistent trust plus approvals scoped to the current connection
    /// journey. Temporary approvals never enter SwiftData or sync.
    func expectedHostKeys(
        for host: Host, temporaryHostKeys: [Host.ID: SSHHostKeyIdentity] = [:]
    ) throws -> Set<SSHHostKeyIdentity> {
        var keys = Set(knownHosts(for: host).map(\.identity))
        if let temporary = temporaryHostKeys[host.id] {
            keys.insert(temporary)
        }
        guard !keys.isEmpty else { throw TermindSSHError.untrustedHost }
        return keys
    }

    /// Why a saved host cannot currently receive a key without stopping for
    /// another question. Export is deliberately limited to hosts whose login
    /// and host-key trust have already been established elsewhere in the app.
    func keyExportUnavailableReason(for host: Host) -> String? {
        guard let identity = identity(for: host) else {
            return String(localized: "No identity")
        }
        guard !identity.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "No username")
        }
        let hasAvailablePassword = passwordAvailability(for: identity) == .available
        let hasUsableKey = identity.keyID.flatMap { key($0) }.map {
            keyAvailability(for: $0) == .available
        } == true
        guard hasAvailablePassword || hasUsableKey else {
            return String(localized: "No saved credential")
        }
        let knownHosts = knownHosts(for: host)
        guard !knownHosts.isEmpty else {
            return String(localized: "Connect once to trust this host")
        }
        guard !knownHosts.contains(where: \.isMismatched) else {
            return String(localized: "Host key changed")
        }
        return nil
    }

    /// Resolves model references and Keychain secrets before work leaves the
    /// main actor. The resulting value is Sendable and contains no persistence
    /// objects, so several one-shot exports can safely run in parallel.
    func sshConnectionConfiguration(
        for host: Host,
        submissions: [Host.ID: SSHAuthenticationSubmission] = [:],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity] = [:]
    ) throws -> SSHConnectionConfiguration {
        let username: String
        let credentials: [SSHCredentials]
        if let submission = submissions[host.id] {
            username = submission.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else { throw TermindSSHError.missingUsername }
            credentials = try sshCredentials(for: submission)
        } else {
            guard let identity = identity(for: host) else {
                throw TermindSSHError.missingCredential
            }
            username = identity.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else { throw TermindSSHError.missingUsername }
            let resolution = sshCredentials(for: identity)
            guard resolution.requiredPassphraseKeyID == nil else {
                throw TermindSSHError.keyPassphraseRequired
            }
            credentials = resolution.credentials
        }
        guard !credentials.isEmpty else { throw TermindSSHError.missingCredential }
        let expectedHostKeys = try expectedHostKeys(
            for: host, temporaryHostKeys: temporaryHostKeys
        )

        guard let route = validatedRoute(for: host) else {
            throw TermindSSHError.route(String(localized: "The Jump Host route is invalid or exceeds eight hosts."))
        }
        let jumps = try route.dropLast().enumerated().map { offset, jump in
            do {
                if let submission = submissions[jump.id] {
                    return try sshRouteHopConfiguration(
                        for: jump, submission: submission,
                        temporaryHostKeys: temporaryHostKeys
                    )
                }
                return try sshRouteHopConfiguration(
                    for: jump, temporaryHostKeys: temporaryHostKeys
                )
            } catch {
                let authentication =
                    switch error as? TermindSSHError {
                    case .missingCredential, .missingUsername, .keyPassphraseRequired: true
                    default: false
                    }
                let hostKey =
                    switch error as? TermindSSHError {
                    case .untrustedHost: true
                    default: false
                    }
                throw TermindSSHError.routeHost(
                    hostID: jump.id, authentication: authentication,
                    serverChallenge: false, hostKey: hostKey,
                    message: String(localized: "Jump Host \(offset + 1) (\(jump.name)): \(error.localizedDescription)")
                )
            }
        }

        return SSHConnectionConfiguration(
            hostID: host.id, host: host.host, port: host.port, username: username,
            credentials: credentials,
            expectedHostKeys: expectedHostKeys,
            proxy: try transportProxy(for: host), jumps: jumps
        )
    }

    func sshJumpConfigurations(
        for host: Host,
        submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity] = [:]
    ) throws -> [SSHRouteHopConfiguration] {
        guard let route = validatedRoute(for: host) else {
            throw TermindSSHError.route(String(localized: "The Jump Host route is invalid or exceeds eight hosts."))
        }
        return try route.dropLast().enumerated().map { offset, jump in
            do {
                if let submission = submissions[jump.id] {
                    return try sshRouteHopConfiguration(
                        for: jump, submission: submission,
                        temporaryHostKeys: temporaryHostKeys
                    )
                }
                return try sshRouteHopConfiguration(
                    for: jump, temporaryHostKeys: temporaryHostKeys
                )
            } catch {
                let authentication =
                    switch error as? TermindSSHError {
                    case .missingCredential, .missingUsername, .keyPassphraseRequired: true
                    default: false
                    }
                let hostKey =
                    switch error as? TermindSSHError {
                    case .untrustedHost: true
                    default: false
                    }
                throw TermindSSHError.routeHost(
                    hostID: jump.id, authentication: authentication,
                    serverChallenge: false, hostKey: hostKey,
                    message: String(localized: "Jump Host \(offset + 1) (\(jump.name)): \(error.localizedDescription)")
                )
            }
        }
    }

    private func sshRouteHopConfiguration(
        for host: Host, temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    ) throws -> SSHRouteHopConfiguration {
        guard let identity = identity(for: host) else { throw TermindSSHError.missingCredential }
        let username = identity.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { throw TermindSSHError.missingUsername }
        let expectedHostKeys = try expectedHostKeys(
            for: host, temporaryHostKeys: temporaryHostKeys
        )
        let resolution = sshCredentials(for: identity)
        guard resolution.requiredPassphraseKeyID == nil else {
            throw TermindSSHError.keyPassphraseRequired
        }
        guard !resolution.credentials.isEmpty else { throw TermindSSHError.missingCredential }
        return SSHRouteHopConfiguration(
            id: host.id, name: host.name, host: host.host, port: host.port,
            username: username, credentials: resolution.credentials,
            expectedHostKeys: expectedHostKeys,
            proxy: try transportProxy(for: host)
        )
    }

    private func sshRouteHopConfiguration(
        for host: Host, submission: SSHAuthenticationSubmission,
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    ) throws -> SSHRouteHopConfiguration {
        let username = submission.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { throw TermindSSHError.missingUsername }
        let expectedHostKeys = try expectedHostKeys(
            for: host, temporaryHostKeys: temporaryHostKeys
        )
        let credentials = try sshCredentials(for: submission)
        guard !credentials.isEmpty else { throw TermindSSHError.missingCredential }
        return SSHRouteHopConfiguration(
            id: host.id, name: host.name, host: host.host, port: host.port,
            username: username, credentials: credentials,
            expectedHostKeys: expectedHostKeys,
            proxy: try transportProxy(for: host)
        )
    }

    private func sshCredentials(
        for submission: SSHAuthenticationSubmission
    ) throws -> [SSHCredentials] {
        var credentials: [SSHCredentials] = []
        if let keyID = submission.keyID, let key = key(keyID) {
            if key.requiresPassphraseEntry,
                submission.passphrase?.isEmpty != false
            {
                throw TermindSSHError.keyPassphraseRequired
            }
            if let stored = try keyCredential(for: key) {
                credentials.append(
                    stored.sshCredential(
                        publicKey: key.publicKey, certificate: key.certificate,
                        passphraseOverride: submission.passphrase
                    )
                )
            }
        }
        if let password = submission.password { credentials.append(.password(password)) }
        return credentials
    }

    func transportProxy(for host: Host) throws -> SSHTransportProxy? {
        guard let proxy = host.proxy else { return nil }
        guard proxy.isValid else {
            throw TermindSSHError.proxy(String(localized: "The proxy configuration is incomplete."))
        }
        var password: String?
        if let identityID = proxy.identityID {
            guard let identity = identity(identityID), identity.usesPassword else {
                throw TermindSSHError.proxy(String(localized: "The proxy password identity is unavailable."))
            }
            password = try passwordCredential(for: identity)
            guard password != nil else {
                throw TermindSSHError.proxy(String(localized: "The proxy password is unavailable."))
            }
        }
        return SSHTransportProxy(
            kind: proxy.kind, hostname: proxy.hostname, port: proxy.port,
            username: proxy.username, password: password
        )
    }

    /// Loads Key and Password independently so one damaged or missing Keychain
    /// item does not suppress the other usable credential.
    func sshCredentials(for identity: Identity) -> SSHCredentialResolution {
        var credentials: [SSHCredentials] = []
        var failures: [String] = []
        var requiredPassphraseKeyID: SSHKeyRef.ID?

        if let keyID = identity.keyID {
            if let key = key(keyID) {
                do {
                    if let credential = try keyCredential(for: key) {
                        if key.requiresPassphraseEntry {
                            requiredPassphraseKeyID = key.id
                        } else {
                            credentials.append(
                                credential.sshCredential(
                                    publicKey: key.publicKey, certificate: key.certificate
                                )
                            )
                        }
                    } else {
                        failures.append(
                            String(localized: "The selected key has no saved private key.")
                        )
                    }
                } catch {
                    storageError = error.localizedDescription
                    failures.append(error.localizedDescription)
                }
            } else {
                failures.append(
                    String(localized: "The selected key is no longer available.")
                )
            }
        }

        if identity.usesPassword {
            do {
                if let password = try passwordCredential(for: identity) {
                    credentials.append(.password(password))
                } else {
                    failures.append(
                        String(localized: "The saved password is no longer available.")
                    )
                }
            } catch {
                storageError = error.localizedDescription
                failures.append(error.localizedDescription)
            }
        }

        return SSHCredentialResolution(
            credentials: credentials, failures: failures,
            hasConfiguredCredential: identity.hasSecret,
            requiredPassphraseKeyID: requiredPassphraseKeyID
        )
    }

    /// Every host tag, deduplicated case-insensitively and sorted.
    var allTags: [String] {
        uniqueSortedTags(hosts.flatMap(\.tags))
    }

    /// Tags in use on hosts. What the Hosts page offers to filter by: a
    /// snippet-only tag there would be a filter that matches nothing.
    var hostTags: [String] {
        uniqueSortedTags(hosts.flatMap(\.tags))
    }

    private func uniqueSortedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        let uniqueTags = tags.filter { seen.insert($0.lowercased()).inserted }
        return uniqueTags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Search

    /// Also matches the resolved identity, so filtering by `deploy` still finds
    /// every box that logs in as `deploy` now that the name lives one hop away.
    func searchHosts(_ query: String) -> [Host] {
        hosts
            .filter { host in
                host.matches(query)
                    || loginAddress(for: host).localizedCaseInsensitiveContains(query)
                    || (!query.isEmpty && identity(for: host)?.matches(query) == true)
            }
            .sorted { $0.name < $1.name }
    }

    func searchSnippets(_ query: String) -> [Snippet] {
        snippets.filter {
            $0.matches(query)
                || (!query.isEmpty
                    && snippetPackagePath($0.packageID)?.localizedCaseInsensitiveContains(query) == true)
        }.sorted { $0.sortIndex < $1.sortIndex }
    }

    func searchKeys(_ query: String) -> [SSHKeyRef] {
        keys
            .filter { key in
                query.isEmpty
                    || key.label.localizedCaseInsensitiveContains(query)
                    || key.fingerprint.localizedCaseInsensitiveContains(query)
            }
            .sorted { manuallyOrdered($0.sortIndex, $0.label, $1.sortIndex, $1.label) }
    }

    func searchIdentities(_ query: String) -> [Identity] {
        identities.filter { $0.matches(query) }.sorted {
            manuallyOrdered($0.sortIndex, $0.name, $1.sortIndex, $1.name)
        }
    }

    // MARK: - Writes

    func upsert(_ host: Host) {
        guard validatedRoute(for: host) != nil else {
            storageError = String(localized: "The selected jump host creates a routing loop or exceeds 8 hops.")
            return
        }
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            var new = host
            new.sortIndex = nextSortIndex(in: host.groupID)
            hosts.append(new)
        }
        persistCore()
    }

    /// Commits one host and its complete editor-owned collections together.
    ///
    /// `HostEditorView` owns the Host, forwarding rules, and Known Hosts as
    /// drafts, so persisting them through separate calls would let Save only
    /// partly succeed. The in-memory projections are
    /// restored if SwiftData rejects the replacement, and rules whose live
    /// connection would no longer match the saved configuration are stopped
    /// before their old records disappear.
    @discardableResult
    func upsert(
        _ host: Host,
        replacingPortForwardings rules: [PortForwardingRule],
        replacingKnownHosts knownHostEntries: [KnownHostEntry]? = nil
    ) -> Bool {
        guard validatedRoute(for: host) != nil else {
            storageError = String(localized: "The selected jump host creates a routing loop or exceeds 8 hops.")
            return false
        }
        let normalizedRules = rules.map { rule in
            var normalized = rule
            normalized.hostID = host.id
            if normalized.kind == .dynamic {
                normalized.targetHost = nil
                normalized.targetPort = nil
            }
            return normalized
        }
        guard normalizedRules.allSatisfy(\.isValid),
            Set(normalizedRules.map(\.id)).count == normalizedRules.count
        else {
            storageError = String(localized: "One or more forwarding rules are incomplete.")
            return false
        }

        let normalizedKnownHosts = knownHostEntries.map { entries in
            entries.map { entry in
                var normalized = entry
                normalized.hostname = host.host
                normalized.port = host.port
                normalized.fingerprint = entry.fingerprint.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                return normalized
            }
        }
        if let normalizedKnownHosts {
            let identities = normalizedKnownHosts.map(\.identity)
            guard
                normalizedKnownHosts.allSatisfy({
                    !$0.fingerprint.isEmpty
                }),
                Set(normalizedKnownHosts.map(\.id)).count == normalizedKnownHosts.count,
                Set(identities).count == identities.count
            else {
                storageError = String(localized: "One or more Known Hosts entries are incomplete or duplicated.")
                return false
            }
        }

        let oldHosts = hosts
        let oldRules = portForwardings
        let oldKnownHosts = knownHosts
        let existingHost = self.host(host.id)
        let existingRules = portForwardings(for: host.id)
        let nextByID = Dictionary(uniqueKeysWithValues: normalizedRules.map { ($0.id, $0) })
        var rulesToStop = Set(
            existingRules.compactMap { old in nextByID[old.id] == old ? nil : old.id }
        )
        if let existingHost, existingHost.sshConnectionFields != host.sshConnectionFields {
            rulesToStop.formUnion(existingRules.map(\.id))
        }
        if !rulesToStop.isEmpty { willDeletePortForwardings?(Array(rulesToStop)) }

        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            var new = host
            new.sortIndex = nextSortIndex(in: host.groupID)
            hosts.append(new)
        }
        portForwardings.removeAll { $0.hostID == host.id }
        portForwardings.append(contentsOf: normalizedRules)
        if let normalizedKnownHosts {
            if let existingHost {
                knownHosts.removeAll {
                    $0.hostname == existingHost.host && $0.port == existingHost.port
                }
            }
            knownHosts.removeAll { $0.hostname == host.host && $0.port == host.port }
            knownHosts.append(contentsOf: normalizedKnownHosts)
        }

        guard persistCore() else {
            hosts = oldHosts
            portForwardings = oldRules
            knownHosts = oldKnownHosts
            return false
        }
        return true
    }

    func delete(hostID: Host.ID) {
        willDeleteHost?(hostID, portForwardings(for: hostID).map(\.id))
        hosts.removeAll { $0.id == hostID }
        for index in hosts.indices where hosts[index].jumpHostID == hostID {
            hosts[index].jumpHostID = nil
        }
        for index in snippets.indices {
            snippets[index].targetHostIDs.removeAll { $0 == hostID }
        }
        portForwardings.removeAll { $0.hostID == hostID }
        connectionStatuses = connectionStatuses.filter { $0.value.hostID != hostID }
        statuses[hostID] = nil
        persistCore()
    }

    /// Transitional in-memory projection for repository-owned durable deletion.
    /// The repository is the only writer; this keeps legacy views in sync until
    /// they consume `HostLibraryModel` directly.
    func projectHostDeletion(_ hostID: Host.ID) {
        hosts.removeAll { $0.id == hostID }
        for index in hosts.indices where hosts[index].jumpHostID == hostID {
            hosts[index].jumpHostID = nil
        }
        for index in snippets.indices {
            snippets[index].targetHostIDs.removeAll { $0 == hostID }
        }
        portForwardings.removeAll { $0.hostID == hostID }
        connectionStatuses = connectionStatuses.filter { $0.value.hostID != hostID }
        statuses[hostID] = nil
    }

    func setStatus(_ status: ConnectionStatus, for id: Host.ID) {
        statuses[id] = status
    }

    /// Records one live connection's state and projects terminals and File
    /// Transfer browsers for the same host into the status dot shown by Hosts
    /// and host pickers. A connected source wins over a connecting or failed
    /// sibling, so closing one pane cannot make an otherwise-online host appear
    /// offline.
    func setConnectionStatus(
        _ status: ConnectionStatus, connectionID: UUID, hostID: Host.ID
    ) {
        if status == .disconnected {
            connectionStatuses[connectionID] = nil
        } else {
            connectionStatuses[connectionID] = (hostID, status)
        }
        refreshStatus(for: hostID)
    }

    func setSSHSessionStatus(
        _ status: ConnectionStatus, sshSessionID: UUID, hostID: Host.ID
    ) {
        setConnectionStatus(status, connectionID: sshSessionID, hostID: hostID)
    }

    private func refreshStatus(for hostID: Host.ID) {
        let active = connectionStatuses.values
            .filter { $0.hostID == hostID }
            .map(\.status)
        if active.contains(.connected) {
            statuses[hostID] = .connected
        } else if active.contains(.reconnecting) {
            statuses[hostID] = .reconnecting
        } else if active.contains(.connecting) {
            statuses[hostID] = .connecting
        } else if let failure = active.first(where: {
            if case .failed = $0 { return true }
            return false
        }) {
            statuses[hostID] = failure
        } else {
            statuses[hostID] = nil
        }
    }

    /// Drops a pinned host key. The next connection to that host is treated as a
    /// first connection, which is the whole point — it is the escape hatch for a
    /// server that was legitimately rekeyed.
    func forget(knownHost id: KnownHostEntry.ID) {
        knownHosts.removeAll { $0.id == id }
        persistCore()
    }

    func forgetKnownHosts(for host: Host) {
        knownHosts.removeAll { $0.hostname == host.host && $0.port == host.port }
        persistCore()
    }

    func trust(_ entry: KnownHostEntry) {
        let endpointMatches: (KnownHostEntry) -> Bool = {
            $0.hostname == entry.hostname && $0.port == entry.port
        }
        for index in knownHosts.indices where endpointMatches(knownHosts[index]) {
            knownHosts[index].isMismatched = false
        }
        if let index = knownHosts.firstIndex(where: {
            endpointMatches($0) && $0.fingerprint == entry.fingerprint
        }) {
            let retainedID = knownHosts[index].id
            knownHosts[index].algorithm = entry.algorithm
            knownHosts[index].addedAt = entry.addedAt
            knownHosts.removeAll {
                $0.id != retainedID && endpointMatches($0)
                    && $0.fingerprint == entry.fingerprint
            }
        } else {
            knownHosts.append(entry)
        }
        persistCore()
    }

    func markKnownHostMismatched(hostname: String, port: Int) {
        var changed = false
        for index in knownHosts.indices
        where knownHosts[index].hostname == hostname && knownHosts[index].port == port {
            knownHosts[index].isMismatched = true
            changed = true
        }
        if changed { persistCore() }
    }

    func setExpanded(_ expanded: Bool, for groupID: HostGroup.ID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].isExpanded = expanded
        persistCore()
    }

    func setUngroupedExpanded(_ expanded: Bool) {
        isUngroupedExpanded = expanded
    }

    func setSnippetPackageExpanded(_ expanded: Bool, for packageID: SnippetPackage.ID) {
        guard let index = snippetPackages.firstIndex(where: { $0.id == packageID }) else { return }
        snippetPackages[index].isExpanded = expanded
        persistCore()
    }

    func setSnippetsUngroupedExpanded(_ expanded: Bool) {
        isSnippetsUngroupedExpanded = expanded
    }

    /// Adds or updates an identity. New ones land at the end of the list, which
    /// is sorted by name wherever it is shown, so there is no order to keep.
    @discardableResult
    func upsert(_ identity: Identity) -> Bool {
        if let index = identities.firstIndex(where: { $0.id == identity.id }) {
            var updated = identity
            updated.sortIndex = identities[index].sortIndex
            identities[index] = updated
        } else {
            var new = identity
            new.sortIndex = (identities.map(\.sortIndex).max() ?? -1) + 1
            identities.append(new)
        }
        if !identity.isProxyEligible {
            for index in hosts.indices where hosts[index].proxy?.identityID == identity.id {
                hosts[index].proxy?.identityID = nil
                hosts[index].proxy?.username = ""
            }
        }
        return persistCore()
    }

    /// Updates an Identity and its Keychain password as one operation.
    ///
    /// The editor supplies intent rather than an optional string so a blank
    /// field can keep an existing password while an explicit remove action can
    /// delete it. The old reference is resolved here, before the model changes,
    /// which prevents a cleared Identity from making its former Keychain item
    /// unreachable.
    func upsert(_ identity: Identity, passwordUpdate: IdentityPasswordUpdate) throws {
        let previousIdentity = self.identity(identity.id)
        let previousReference = previousIdentity?.credentialRef ?? identity.credentialRef
        let previousStorage = previousIdentity?.passwordStorage ?? identity.passwordStorage
        var updated = identity

        let oldPassword =
            previousReference.isEmpty
            ? nil : try keychain.string(for: previousReference, storage: previousStorage)
        let identitySnapshot = identities
        let hostSnapshot = hosts
        var wroteDestination = false
        do {
            switch passwordUpdate {
            case .keep:
                updated.credentialRef = previousReference
                if previousStorage != updated.passwordStorage, !previousReference.isEmpty {
                    guard let oldPassword else {
                        throw TermindSSHError.library(
                            String(localized: "The saved password is unavailable on this Mac. Enter it again before changing storage.")
                        )
                    }
                    try keychain.setString(
                        oldPassword, for: previousReference, storage: updated.passwordStorage
                    )
                    wroteDestination = true
                }
            case .replace(let password):
                guard !password.isEmpty else {
                    throw TermindSSHError.library(
                        String(localized: "A replacement password cannot be empty.")
                    )
                }
                let reference =
                    previousReference.isEmpty
                    ? "termind.password.\(UUID().uuidString)"
                    : previousReference
                try keychain.setString(password, for: reference, storage: updated.passwordStorage)
                wroteDestination = true
                updated.credentialRef = reference
            case .remove:
                updated.credentialRef = ""
            }
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            throw error
        }

        guard upsert(updated) else {
            identities = identitySnapshot
            hosts = hostSnapshot
            do {
                if wroteDestination {
                    if updated.passwordStorage == previousStorage, let oldPassword {
                        try keychain.setString(
                            oldPassword, for: previousReference, storage: previousStorage
                        )
                    } else if !updated.credentialRef.isEmpty {
                        try keychain.removePassword(
                            updated.credentialRef, storage: updated.passwordStorage
                        )
                    }
                }
            } catch {
                storageError = String(
                    localized: "The database save and Keychain rollback both failed: \(error.localizedDescription)"
                )
            }
            throw TermindSSHError.library(
                storageError ?? String(localized: "The identity could not be saved.")
            )
        }

        let removesPrevious =
            !previousReference.isEmpty
            && (updated.credentialRef.isEmpty || previousStorage != updated.passwordStorage)
        if removesPrevious {
            do {
                try keychain.removePassword(previousReference, storage: previousStorage)
            } catch {
                // The newly committed destination stays authoritative. Retaining
                // the source is safer than rolling a successful save backward.
                storageError = String(
                    localized: "The password was saved, but its previous Keychain copy could not be removed: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Throwing counterpart used by connection setup, where a Keychain failure
    /// must remain distinguishable from an Identity that has no password.
    func passwordCredential(for identity: Identity) throws -> String? {
        guard identity.usesPassword else { return nil }
        return try keychain.string(
            for: identity.credentialRef, storage: identity.passwordStorage
        )
    }

    func passwordAvailability(for identity: Identity) -> SecretAvailability {
        guard identity.usesPassword else { return .notConfigured }
        do {
            return try passwordCredential(for: identity) == nil ? .missing : .available
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func isProxyEligibleOnThisDevice(_ identity: Identity) -> Bool {
        identity.isProxyEligible && passwordAvailability(for: identity) == .available
    }

    /// Removes an identity, along with the password it was the only way to
    /// reach, and unfiles it from every host that logged in with it — those
    /// hosts keep their address and go back to "no login chosen yet".
    @discardableResult
    func delete(identityID: Identity.ID) -> Bool {
        guard let identity = identity(identityID) else { return false }
        let password: String?
        do {
            password =
                identity.credentialRef.isEmpty
                ? nil : try keychain.string(
                    for: identity.credentialRef, storage: identity.passwordStorage
                )
            try keychain.removePassword(
                identity.credentialRef, storage: identity.passwordStorage
            )
        } catch {
            storageError = error.localizedDescription
            return false
        }
        let identitySnapshot = identities
        let hostSnapshot = hosts
        identities.removeAll { $0.id == identityID }
        for index in hosts.indices where hosts[index].identityID == identityID {
            hosts[index].identityID = nil
        }
        for index in hosts.indices where hosts[index].proxy?.identityID == identityID {
            hosts[index].proxy?.identityID = nil
            hosts[index].proxy?.username = ""
        }
        guard persistCore() else {
            identities = identitySnapshot
            hosts = hostSnapshot
            if let password {
                do {
                    try keychain.setString(
                        password, for: identity.credentialRef,
                        storage: identity.passwordStorage
                    )
                } catch {
                    storageError = String(
                        localized: "The database save and Keychain rollback both failed: \(error.localizedDescription)"
                    )
                }
            }
            return false
        }
        return true
    }

    func upsert(_ key: SSHKeyRef, credential: StoredSSHKeyCredential? = nil) throws {
        let previousKey = self.key(key.id)
        if key.storage == .secureEnclave, !key.certificate.isEmpty {
            throw TermindSSHError.library(
                String(localized: "Secure Enclave keys cannot store an SSH certificate.")
            )
        }
        if !key.certificate.isEmpty {
            _ = try SSHUserCertificate.parse(key.certificate, matching: key.publicKey)
        }
        let keySnapshot = keys
        let changesLocation = previousKey.map {
            $0.storage != key.storage || $0.credentialRef != key.credentialRef
        } ?? false
        if changesLocation,
            previousKey?.storage == .secureEnclave || key.storage == .secureEnclave
        {
            throw TermindSSHError.library(
                String(localized: "Secure Enclave keys cannot be moved to another storage location.")
            )
        }
        let previousCredential = try (credential != nil || changesLocation)
            ? previousKey.flatMap { try keyCredential(for: $0) }
            : nil
        let destinationCredential = credential ?? (changesLocation ? previousCredential : nil)
        if let destinationCredential {
            try keychain.setKeyCredential(
                destinationCredential, for: key.credentialRef, storage: key.storage
            )
        }
        if let index = keys.firstIndex(where: { $0.id == key.id }) {
            var updated = key
            updated.sortIndex = keys[index].sortIndex
            keys[index] = updated
        } else {
            var new = key
            new.sortIndex = (keys.map(\.sortIndex).max() ?? -1) + 1
            keys.append(new)
        }
        guard persistCore() else {
            keys = keySnapshot
            do {
                if changesLocation, destinationCredential != nil {
                    try keychain.removeKeyCredential(
                        key.credentialRef, storage: key.storage
                    )
                } else if destinationCredential != nil, let previousKey, let previousCredential {
                    try keychain.setKeyCredential(
                        previousCredential, for: previousKey.credentialRef,
                        storage: previousKey.storage
                    )
                } else if destinationCredential != nil {
                    try keychain.removeKeyCredential(key.credentialRef, storage: key.storage)
                }
            } catch {
                storageError = String(
                    localized: "The database save and Keychain rollback both failed: \(error.localizedDescription)"
                )
            }
            throw TermindSSHError.library(
                storageError ?? String(localized: "The key could not be saved.")
            )
        }

        if changesLocation, let previousKey {
            do {
                try keychain.removeKeyCredential(
                    previousKey.credentialRef, storage: previousKey.storage
                )
            } catch {
                storageError = String(
                    localized: "The key was saved, but its previous Keychain copy could not be removed: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Reorders Keys without allowing them to leave their fixed Keychain
    /// section. The supplied order is the order of a multi-card drag.
    func move(keyIDs: [SSHKeyRef.ID], before next: SSHKeyRef.ID? = nil) {
        guard
            reorderManually(
                keyIDs, before: next, items: &keys, sortIndex: \SSHKeyRef.sortIndex
            )
        else { return }
        persistCore()
    }

    /// Reorders Identities independently from Keys. A mixed Keychain selection
    /// is split by the page before it reaches this fixed-section operation.
    func move(identityIDs: [Identity.ID], before next: Identity.ID? = nil) {
        guard
            reorderManually(
                identityIDs, before: next, items: &identities,
                sortIndex: \Identity.sortIndex
            )
        else { return }
        persistCore()
    }

    func keyCredential(for key: SSHKeyRef) throws -> StoredSSHKeyCredential? {
        try keychain.keyCredential(for: key.credentialRef, storage: key.storage)
    }

    func keyAvailability(for key: SSHKeyRef) -> SecretAvailability {
        do {
            return try keyCredential(for: key) == nil ? .missing : .available
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func delete(keyID: SSHKeyRef.ID) throws {
        guard let key = key(keyID) else { return }
        let credential = try keyCredential(for: key)
        try keychain.removeKeyCredential(key.credentialRef, storage: key.storage)
        let keySnapshot = keys
        let identitySnapshot = identities
        keys.removeAll { $0.id == keyID }
        for index in identities.indices where identities[index].keyID == keyID {
            identities[index].keyID = nil
        }
        guard persistCore() else {
            keys = keySnapshot
            identities = identitySnapshot
            if let credential {
                try keychain.setKeyCredential(
                    credential, for: key.credentialRef, storage: key.storage
                )
            }
            throw TermindSSHError.library(
                storageError ?? String(localized: "The key could not be deleted.")
            )
        }
    }

    /// Adds or updates a group. A new group is placed after its last sibling
    /// rather than at the end of the flat array — `sortIndex` is per-parent, so
    /// a child of Production has to be numbered against Production's children.
    func upsert(_ group: HostGroup) {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            var new = group
            new.sortIndex = nextSortIndex(under: group.parentID)
            groups.append(new)
        }
        persistCore()
    }

    /// Deletes a group and every group beneath it.
    ///
    /// The nested groups are not negotiable — a child whose parent is gone has
    /// nowhere to hang — but the *hosts* are, which is the whole reason this
    /// takes a flag instead of just doing something. `keepHosts` unfiles them to
    /// Ungrouped; otherwise they go through `delete(hostID:)`, which is what
    /// also clears their port forwards and live status. Removing them from the
    /// array directly would leave both behind, pointing at a host id that no
    /// longer resolves.
    func delete(groupID: HostGroup.ID, keepHosts: Bool) {
        let doomed = Set([groupID] + descendantGroups(of: groupID).map(\.id))
        let affected = hosts.filter { host in host.groupID.map(doomed.contains) ?? false }

        if keepHosts {
            for index in hosts.indices where hosts[index].groupID.map(doomed.contains) ?? false {
                hosts[index].groupID = nil
            }
        } else {
            for host in affected {
                delete(hostID: host.id)
            }
        }

        groups.removeAll { doomed.contains($0.id) }
        persistCore()
    }

    func upsert(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            var updated = snippet
            if snippets[index].packageID == updated.packageID {
                updated.sortIndex = snippets[index].sortIndex
            } else {
                updated.sortIndex = nextSnippetSortIndex(in: updated.packageID)
            }
            snippets[index] = updated
        } else {
            var new = snippet
            new.sortIndex = nextSnippetSortIndex(in: snippet.packageID)
            snippets.append(new)
        }
        persistCore()
    }

    func delete(snippetIDs: [Snippet.ID]) {
        let doomed = Set(snippetIDs)
        snippets.removeAll { doomed.contains($0.id) }
        persistCore()
    }

    func upsert(_ package: SnippetPackage) {
        if let index = snippetPackages.firstIndex(where: { $0.id == package.id }) {
            let forbidden = Set(
                [package.id] + descendantSnippetPackages(of: package.id).map(\.id)
            )
            guard package.parentID.map(forbidden.contains) != true else { return }
            var updated = package
            if snippetPackages[index].parentID != updated.parentID {
                updated.sortIndex = nextSnippetPackageSortIndex(under: updated.parentID)
            }
            snippetPackages[index] = updated
        } else {
            guard package.parentID != package.id else { return }
            var new = package
            new.sortIndex = nextSnippetPackageSortIndex(under: package.parentID)
            snippetPackages.append(new)
        }
        expandSnippetPackageAncestors(package.id)
        persistCore()
    }

    func delete(snippetPackageID: SnippetPackage.ID, keepSnippets: Bool) {
        let doomed = Set(
            [snippetPackageID] + descendantSnippetPackages(of: snippetPackageID).map(\.id)
        )
        if keepSnippets {
            for index in snippets.indices where snippets[index].packageID.map(doomed.contains) == true {
                snippets[index].packageID = nil
                snippets[index].sortIndex = nextSnippetSortIndex(in: nil)
            }
        } else {
            snippets.removeAll { $0.packageID.map(doomed.contains) == true }
        }
        snippetPackages.removeAll { doomed.contains($0.id) }
        persistCore()
    }

    func move(
        snippetIDs: [Snippet.ID], into packageID: SnippetPackage.ID?,
        before next: Snippet.ID? = nil
    ) {
        if let packageID, snippetPackage(packageID) == nil { return }
        guard
            let placement = manualOrderPlacement(
                snippetIDs, before: next,
                destinationItems: snippets(in: packageID),
                validIDs: Set(snippets.map(\.id)), sortIndex: \Snippet.sortIndex
            )
        else { return }
        if placement.moving.allSatisfy({ snippet($0)?.packageID == packageID })
            && snippets(in: packageID).map(\.id) == placement.resulting
        {
            return
        }

        let moving = Set(placement.moving)
        for index in snippets.indices {
            if moving.contains(snippets[index].id) { snippets[index].packageID = packageID }
            if let position = placement.positions[snippets[index].id] {
                snippets[index].sortIndex = position
            }
        }
        expandSnippetPackageAncestors(packageID)
        persistCore()
    }

    func upsert(_ forwarding: PortForwardingRule) {
        guard forwarding.isValid, host(forwarding.hostID) != nil else { return }
        var normalized = forwarding
        if normalized.kind == .dynamic {
            normalized.targetHost = nil
            normalized.targetPort = nil
        }
        if let index = portForwardings.firstIndex(where: { $0.id == normalized.id }) {
            portForwardings[index] = normalized
        } else {
            portForwardings.append(normalized)
        }
        persistCore()
    }

    /// Root jump first and destination last. A nil result means the proposed
    /// host closes a cycle, references a missing jump, or exceeds eight hosts.
    func validatedRoute(for proposed: Host) -> [Host]? {
        var route: [Host] = []
        var cursor: Host? = proposed
        var visited: Set<Host.ID> = []
        while let current = cursor {
            guard visited.insert(current.id).inserted, route.count < 8 else { return nil }
            route.append(current)
            guard let jumpID = current.jumpHostID else { break }
            if jumpID == proposed.id { return nil }
            cursor = jumpID == proposed.id ? proposed : host(jumpID)
            if cursor == nil { return nil }
        }
        return route.reversed()
    }

    func route(for host: Host) -> [Host] {
        validatedRoute(for: host) ?? [host]
    }

    func routeSummary(for host: Host) -> String {
        route(for: host).map { node in
            if let proxy = node.proxy {
                return "\(proxy.kind.displayName) \(proxy.hostname):\(proxy.port) → \(node.displayAddress)"
            }
            return node.displayAddress
        }.joined(separator: " → ")
    }

    /// OpenSSH equivalent when the route needs no in-process Proxy. Passwords,
    /// private keys, and proxy credentials never enter the clipboard.
    func sshCommand(for host: Host) -> String? {
        sshCommand(for: host, additionalArguments: [])
    }

    func sshCommand(for rule: PortForwardingRule, host proposedHost: Host? = nil) -> String? {
        guard let destination = proposedHost ?? host(rule.hostID), destination.id == rule.hostID
        else { return nil }
        var arguments = ["-N"]
        switch rule.kind {
        case .local:
            guard let host = rule.targetHost, let port = rule.targetPort else { return nil }
            arguments += ["-L", "\(rule.bindAddress):\(Self.commandAddress(host, port: port))"]
        case .remote:
            guard let host = rule.targetHost, let port = rule.targetPort else { return nil }
            arguments += ["-R", "\(rule.bindAddress):\(Self.commandAddress(host, port: port))"]
        case .dynamic:
            arguments += ["-D", rule.bindAddress]
        }
        return sshCommand(for: destination, additionalArguments: arguments)
    }

    private func sshCommand(for destination: Host, additionalArguments: [String]) -> String? {
        guard let route = validatedRoute(for: destination),
            route.allSatisfy({ $0.proxy == nil })
        else { return nil }

        let jumps = route.dropLast().map { node in
            Self.openSSHAddress(
                host: node.host, port: node.port,
                username: identity(for: node)?.username, bracketsIPv6: true
            )
        }
        var arguments = ["ssh"] + additionalArguments
        if !jumps.isEmpty { arguments += ["-J", jumps.joined(separator: ",")] }
        if destination.port != 22 { arguments += ["-p", String(destination.port)] }
        arguments.append(
            Self.openSSHAddress(
                host: destination.host, port: 22,
                username: identity(for: destination)?.username, bracketsIPv6: false
            )
        )
        return arguments.map(Self.shellQuoted).joined(separator: " ")
    }

    private static func openSSHAddress(
        host: String, port: Int, username: String?, bracketsIPv6: Bool
    ) -> String {
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = bracketsIPv6 && host.contains(":") ? "[\(host)]" : host
        let address = port == 22 ? resolvedHost : "\(resolvedHost):\(port)"
        guard let trimmedUsername, !trimmedUsername.isEmpty else { return address }
        return "\(trimmedUsername)@\(address)"
    }

    /// POSIX-shell quoting for a single argument. Common SSH punctuation stays
    /// readable; everything else uses single quotes without losing apostrophes.
    private static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !value.isEmpty, value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func commandAddress(_ host: String, port: Int) -> String {
        "\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }

    func setSFTPTransferState(_ state: SFTPTransfer.State, for id: SFTPTransfer.ID) {
        guard let index = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[index].state = state
    }

    func enqueueSFTPTransfer(_ sftpTransfer: SFTPTransfer) {
        sftpTransfers.append(sftpTransfer)
    }

    func sftpTransfer(_ id: SFTPTransfer.ID) -> SFTPTransfer? {
        sftpTransfers.first { $0.id == id }
    }

    func updateSFTPTransfer(
        _ id: SFTPTransfer.ID, completedBytes: Int64, totalBytes: Int64,
        bytesPerSecond: Int64
    ) {
        guard let index = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[index].transferredBytes = completedBytes
        sftpTransfers[index].byteCount = totalBytes
        sftpTransfers[index].bytesPerSecond = bytesPerSecond
    }

    func finishSFTPTransfer(_ id: SFTPTransfer.ID, state: SFTPTransfer.State) {
        guard let index = sftpTransfers.firstIndex(where: { $0.id == id }) else { return }
        sftpTransfers[index].state = state
        sftpTransfers[index].bytesPerSecond = 0
        sftpTransfers[index].completedAt = Date()
        if state == .completed {
            sftpTransfers[index].transferredBytes = sftpTransfers[index].byteCount
        }
    }

    /// Clears terminal transfer records while leaving queued and running work
    /// untouched. The transfer center is a current-session history, not a log.
    func clearFinishedSFTPTransfers() {
        sftpTransfers.removeAll {
            switch $0.state {
            case .completed, .cancelled, .failed: true
            case .queued, .running, .paused: false
            }
        }
    }

    /// Files one or more hosts into a group, preserving the order supplied.
    ///
    /// `next` is the host that should follow the moved batch; `nil` appends it.
    /// Updating every host before persisting makes a multi-selection one logical
    /// drag instead of a series of partially saved moves.
    func move(hostIDs: [Host.ID], into group: HostGroup.ID?, before next: Host.ID? = nil) {
        if let group, self.group(group) == nil { return }
        guard
            let placement = manualOrderPlacement(
                hostIDs, before: next,
                destinationItems: hosts(in: group),
                validIDs: Set(hosts.map(\.id)),
                sortIndex: \Host.sortIndex
            )
        else { return }
        if placement.moving.allSatisfy({ host($0)?.groupID == group })
            && hosts(in: group).map(\.id) == placement.resulting
        {
            return
        }

        let movingSet = Set(placement.moving)
        for index in hosts.indices {
            if movingSet.contains(hosts[index].id) { hosts[index].groupID = group }
            if let value = placement.positions[hosts[index].id] {
                hosts[index].sortIndex = value
            }
        }
        persistCore()
    }

    private func nextSortIndex(in group: HostGroup.ID?) -> Double {
        (hosts(in: group).last?.sortIndex ?? 0) + 1
    }

    /// The same, for a group among its siblings. Separate from the hosts version
    /// because the two number different collections: a new child of Production is
    /// placed after Production's last *group*, and the hosts filed directly in
    /// Production have their own independent run of indices.
    private func nextSortIndex(under parent: HostGroup.ID?) -> Double {
        let siblings = parent.map { childGroups(of: $0) } ?? rootGroups
        return (siblings.last?.sortIndex ?? 0) + 1
    }

    private func nextSnippetSortIndex(in package: SnippetPackage.ID?) -> Double {
        (snippets(in: package).last?.sortIndex ?? -1) + 1
    }

    private func nextSnippetPackageSortIndex(under parent: SnippetPackage.ID?) -> Double {
        let siblings = parent.map { childSnippetPackages(of: $0) } ?? rootSnippetPackages
        return (siblings.last?.sortIndex ?? -1) + 1
    }

    private func expandSnippetPackageAncestors(_ packageID: SnippetPackage.ID?) {
        var current = packageID
        var visited: Set<SnippetPackage.ID> = []
        while let id = current, let index = snippetPackages.firstIndex(where: { $0.id == id }),
            visited.insert(id).inserted
        {
            snippetPackages[index].isExpanded = true
            current = snippetPackages[index].parentID
        }
    }

    @discardableResult
    private func persistCore() -> Bool {
        do {
            try vault.save(VaultSnapshot(
                hosts: hosts, groups: groups, identities: identities,
                keys: keys, knownHosts: knownHosts, snippets: snippets,
                snippetPackages: snippetPackages, portForwardings: portForwardings
            ))
            storageError = nil
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    /// Applies a CloudKit-imported projection without writing it back as a new
    /// local edit. Runtime connection and transfer state intentionally remain.
    func replacePersistedSnapshot(_ snapshot: VaultSnapshot) {
        hosts = snapshot.hosts
        groups = snapshot.groups
        identities = normalizedManualOrder(
            snapshot.identities, sortIndex: \Identity.sortIndex, name: \Identity.name
        )
        keys = normalizedManualOrder(
            snapshot.keys, sortIndex: \SSHKeyRef.sortIndex, name: \SSHKeyRef.label
        )
        knownHosts = snapshot.knownHosts
        snippets = normalizedSnippetOrder(snapshot.snippets)
        snippetPackages = snapshot.snippetPackages
        portForwardings = snapshot.portForwardings
        statuses = statuses.filter { id, _ in hosts.contains { $0.id == id } }
        connectionStatuses = connectionStatuses.filter { _, value in
            hosts.contains { $0.id == value.hostID }
        }
        storageError = nil
        vault.didApplyRemoteSnapshot()
    }
}

extension Host {
    fileprivate var sshConnectionFields: SSHConnectionFields {
        SSHConnectionFields(
            host: host, port: port, identityID: identityID,
            jumpHostID: jumpHostID, proxy: proxy
        )
    }
}

private struct SSHConnectionFields: Equatable {
    let host: String
    let port: Int
    let identityID: Identity.ID?
    let jumpHostID: Host.ID?
    let proxy: HostProxy?
}

// MARK: - Manual ordering

/// A deterministic tie-break keeps hand-built preview data usable before its
/// first move. Persisted data normally has unique
/// fractional indices, so the name is not otherwise part of the ordering.
private func manuallyOrdered(
    _ lhsIndex: Double, _ lhsName: String,
    _ rhsIndex: Double, _ rhsName: String
) -> Bool {
    if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
    return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
}

/// Normalize duplicate preview and unit-test defaults once so their first
/// fractional move has real alphabetical neighbours.
private func normalizedManualOrder<Item>(
    _ values: [Item],
    sortIndex: WritableKeyPath<Item, Double>,
    name: KeyPath<Item, String>
) -> [Item] {
    let indices = values.map { $0[keyPath: sortIndex] }
    guard indices.contains(where: { !$0.isFinite }) || Set(indices).count != indices.count else {
        return values
    }

    var ordered = values.sorted {
        manuallyOrdered(
            $0[keyPath: sortIndex], $0[keyPath: name],
            $1[keyPath: sortIndex], $1[keyPath: name]
        )
    }
    for index in ordered.indices { ordered[index][keyPath: sortIndex] = Double(index) }
    return ordered
}

/// Snippet indices are local to a Package. Equal indices in two different
/// Packages are expected, so normalization must never compare them globally.
private func normalizedSnippetOrder(_ values: [Snippet]) -> [Snippet] {
    var result = values
    for packageID in Set(values.map(\.packageID)) {
        let members = result.indices.filter { result[$0].packageID == packageID }
        let sortIndices = members.map { result[$0].sortIndex }
        guard
            sortIndices.contains(where: { !$0.isFinite })
                || Set(sortIndices).count != sortIndices.count
        else { continue }

        let ordered = members.sorted {
            manuallyOrdered(
                result[$0].sortIndex, result[$0].title,
                result[$1].sortIndex, result[$1].title
            )
        }
        for (position, index) in ordered.enumerated() {
            result[index].sortIndex = Double(position)
        }
    }
    return result
}

private struct ManualOrderPlacement<ID: Hashable> {
    let moving: [ID]
    let resulting: [ID]
    let positions: [ID: Double]
}

/// Generic remove-then-insert calculation shared by Hosts, Keys and Identities.
/// The destination may omit moving IDs (Hosts crossing groups), so validity is
/// supplied separately from the concrete destination collection.
private func manualOrderPlacement<Item: Identifiable>(
    _ requestedIDs: [Item.ID],
    before next: Item.ID?,
    destinationItems: [Item],
    validIDs: Set<Item.ID>,
    sortIndex: KeyPath<Item, Double>
) -> ManualOrderPlacement<Item.ID>? where Item.ID: Hashable {
    var seen: Set<Item.ID> = []
    let moving = requestedIDs.filter {
        validIDs.contains($0) && seen.insert($0).inserted
    }
    guard !moving.isEmpty else { return nil }

    let movingSet = Set(moving)
    let remaining = destinationItems.filter { !movingSet.contains($0.id) }
    let insertionIndex: Int
    if let next {
        guard let index = remaining.firstIndex(where: { $0.id == next }) else { return nil }
        insertionIndex = index
    } else {
        insertionIndex = remaining.endIndex
    }

    let resulting =
        Array(remaining[..<insertionIndex]).map(\.id) + moving
        + Array(remaining[insertionIndex...]).map(\.id)
    let lower = insertionIndex > 0 ? remaining[insertionIndex - 1][keyPath: sortIndex] : nil
    let upper = insertionIndex < remaining.endIndex ? remaining[insertionIndex][keyPath: sortIndex] : nil
    var positions: [Item.ID: Double] = [:]

    switch (lower, upper) {
    case (let lower?, let upper?):
        let step = (upper - lower) / Double(moving.count + 1)
        if step.isFinite && step > 0 {
            for (offset, id) in moving.enumerated() {
                positions[id] = lower + step * Double(offset + 1)
            }
        }
    case (let lower?, nil):
        for (offset, id) in moving.enumerated() {
            positions[id] = lower + Double(offset + 1)
        }
    case (nil, let upper?):
        for (offset, id) in moving.enumerated() {
            positions[id] = upper - Double(moving.count - offset)
        }
    case (nil, nil):
        for (offset, id) in moving.enumerated() { positions[id] = Double(offset) }
    }

    if positions.count != moving.count {
        positions = Dictionary(
            uniqueKeysWithValues: resulting.enumerated().map { ($0.element, Double($0.offset)) }
        )
    }
    return ManualOrderPlacement(moving: moving, resulting: resulting, positions: positions)
}

/// Shared fixed-section wrapper for every manually ordered Keychain collection.
private func reorderManually<Item: Identifiable>(
    _ requestedIDs: [Item.ID],
    before next: Item.ID?,
    items: inout [Item],
    sortIndex: WritableKeyPath<Item, Double>
) -> Bool where Item.ID: Hashable {
    let current = items.sorted { $0[keyPath: sortIndex] < $1[keyPath: sortIndex] }
    guard
        let placement = manualOrderPlacement(
            requestedIDs, before: next, destinationItems: current,
            validIDs: Set(current.map(\.id)), sortIndex: sortIndex
        ), placement.resulting != current.map(\.id)
    else { return false }

    for index in items.indices {
        if let value = placement.positions[items[index].id] {
            items[index][keyPath: sortIndex] = value
        }
    }
    items.sort { $0[keyPath: sortIndex] < $1[keyPath: sortIndex] }
    return true
}
