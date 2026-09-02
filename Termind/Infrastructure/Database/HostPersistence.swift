import Foundation
import SwiftData

enum TermindSchemaV7HostModels {
    @Model
    final class PersistentHost {
        @Attribute(.unique) var id: UUID = UUID()
        var name = ""
        var address = ""
        var port = 22
        var identityID: UUID?
        var jumpHostID: UUID?
        var proxyProtocol: String?
        var proxyHostname = ""
        var proxyPort = 0
        var proxyUsername = ""
        var proxyIdentityID: UUID?
        var sftpSessionInitialPath = ""
        var groupID: UUID?
        var tags: [String] = []
        var colorTag = TagColor.none.rawValue
        /// Legacy V1–V5 storage retained only so existing stores can migrate.
        /// Recents and last-connected presentation are derived from connection
        /// history; this column is never read or written by current code.
        var lastUsedAt: Date?
        var sortIndex = 0.0

        init(_ value: Host) {
            id = value.id
            apply(value)
        }

        func apply(_ value: Host) {
            name = value.name
            address = value.host
            port = value.port
            identityID = value.identityID
            jumpHostID = value.jumpHostID
            proxyProtocol = value.proxy?.kind.rawValue
            proxyHostname = value.proxy?.hostname ?? ""
            proxyPort = value.proxy?.port ?? 0
            proxyUsername = value.proxy?.username ?? ""
            proxyIdentityID = value.proxy?.identityID
            sftpSessionInitialPath = value.sftpSessionInitialPath
            groupID = value.groupID
            tags = value.tags
            colorTag = value.colorTag.rawValue
            sortIndex = value.sortIndex
        }

        var value: Host {
            var host = Host(
                id: id, name: name, host: address, port: port,
                identityID: identityID, groupID: groupID, tags: tags,
                colorTag: TagColor(rawValue: colorTag) ?? .none,
                sortIndex: sortIndex
            )
            host.jumpHostID = jumpHostID
            host.sftpSessionInitialPath = sftpSessionInitialPath
            if let proxyProtocol, let kind = HostProxy.ProtocolKind(rawValue: proxyProtocol) {
                host.proxy = HostProxy(
                    kind: kind, hostname: proxyHostname, port: proxyPort,
                    username: proxyUsername, identityID: proxyIdentityID
                )
            }
            return host
        }
    }
}

enum TermindSchemaV8Models {
    @Model
    final class PersistentHost {
        @Attribute(.unique) var id: UUID = UUID()
        var name = ""
        var address = ""
        var port = 22
        var identityID: UUID?
        var jumpHostID: UUID?
        var proxyProtocol: String?
        var proxyHostname = ""
        var proxyPort = 0
        var proxyUsername = ""
        var proxyIdentityID: UUID?
        var sftpSessionInitialPath = ""
        var groupID: UUID?
        var tags: [String] = []
        var colorTag = TagColor.none.rawValue
        var detectedDistributionID: String?
        var detectedDistributionLikeIDs: [String] = []
        /// Legacy storage retained for the existing V5–V6 migration contract.
        var lastUsedAt: Date?
        var sortIndex = 0.0

        init(_ value: Host) {
            id = value.id
            apply(value)
        }

        func apply(_ value: Host) {
            name = value.name
            address = value.host
            port = value.port
            identityID = value.identityID
            jumpHostID = value.jumpHostID
            proxyProtocol = value.proxy?.kind.rawValue
            proxyHostname = value.proxy?.hostname ?? ""
            proxyPort = value.proxy?.port ?? 0
            proxyUsername = value.proxy?.username ?? ""
            proxyIdentityID = value.proxy?.identityID
            sftpSessionInitialPath = value.sftpSessionInitialPath
            groupID = value.groupID
            tags = value.tags
            colorTag = value.colorTag.rawValue
            detectedDistributionID = value.detectedDistribution?.id
            detectedDistributionLikeIDs = value.detectedDistribution?.likeIDs ?? []
            sortIndex = value.sortIndex
        }

        var value: Host {
            var host = Host(
                id: id, name: name, host: address, port: port,
                identityID: identityID, groupID: groupID, tags: tags,
                colorTag: TagColor(rawValue: colorTag) ?? .none,
                detectedDistribution: detectedDistributionID.flatMap {
                    DetectedDistribution(id: $0, likeIDs: detectedDistributionLikeIDs)
                },
                sortIndex: sortIndex
            )
            host.jumpHostID = jumpHostID
            host.sftpSessionInitialPath = sftpSessionInitialPath
            if let proxyProtocol, let kind = HostProxy.ProtocolKind(rawValue: proxyProtocol) {
                host.proxy = HostProxy(
                    kind: kind, hostname: proxyHostname, port: proxyPort,
                    username: proxyUsername, identityID: proxyIdentityID
                )
            }
            return host
        }
    }
}

typealias PersistentHost = TermindSchemaV8Models.PersistentHost

@Model
final class PersistentHostGroup {
    @Attribute(.unique) var id: UUID = UUID()
    var name = ""
    var parentID: UUID?
    var sortIndex = 0.0
    var isExpanded = true

    init(_ value: HostGroup) {
        id = value.id
        apply(value)
    }

    func apply(_ value: HostGroup) {
        name = value.name
        parentID = value.parentID
        sortIndex = value.sortIndex
        isExpanded = value.isExpanded
    }

    var value: HostGroup {
        HostGroup(id: id, name: name, parentID: parentID, sortIndex: sortIndex, isExpanded: isExpanded)
    }
}

@Model
final class PersistentSnippetPackage {
    @Attribute(.unique) var id: UUID = UUID()
    var name = ""
    var parentID: UUID?
    var sortIndex = 0.0
    var isExpanded = true

    init(_ value: SnippetPackage) {
        id = value.id
        apply(value)
    }

    func apply(_ value: SnippetPackage) {
        name = value.name
        parentID = value.parentID
        sortIndex = value.sortIndex
        isExpanded = value.isExpanded
    }

    var value: SnippetPackage {
        SnippetPackage(
            id: id, name: name, parentID: parentID,
            sortIndex: sortIndex, isExpanded: isExpanded
        )
    }
}

@Model
final class PersistentSnippet {
    @Attribute(.unique) var id: UUID = UUID()
    var title = ""
    var body = ""
    var packageID: UUID?
    var targetHostIDs: [UUID] = []
    var sortIndex = 0.0

    init(_ value: Snippet) {
        id = value.id
        apply(value)
    }

    func apply(_ value: Snippet) {
        title = value.title
        body = value.body
        packageID = value.packageID
        targetHostIDs = value.targetHostIDs
        sortIndex = value.sortIndex
    }

    var value: Snippet {
        Snippet(
            id: id, title: title, body: body,
            packageID: packageID, targetHostIDs: targetHostIDs,
            sortIndex: sortIndex
        )
    }
}

/// The V1–V6 shapes are frozen here so adding color fields to the live models
/// does not rewrite the checksums of already-shipped schemas.
enum TermindSchemaV6Models {
    @Model
    final class PersistentIdentity {
        @Attribute(.unique) var id: UUID = UUID()
        var name = ""
        var username = ""
        var credentialRef = ""
        var passwordStorage = PasswordStorage.iCloud.rawValue
        var keyID: UUID?
        var notes = ""
        var lastUsedAt: Date?
        var sortIndex = 0.0

        init(_ value: Identity) {
            id = value.id
            name = value.name
            username = value.username
            credentialRef = value.credentialRef
            passwordStorage = value.passwordStorage.rawValue
            keyID = value.keyID
            notes = value.notes
            lastUsedAt = value.lastUsedAt
            sortIndex = value.sortIndex
        }
    }

    @Model
    final class PersistentSSHKey {
        @Attribute(.unique) var id: UUID = UUID()
        var label = ""
        var algorithm = SSHKeyAlgorithm.ed25519.rawValue
        var publicKey = ""
        var certificate = ""
        var fingerprint = ""
        var credentialRef = ""
        var storage = KeyStorage.iCloud.rawValue
        var keySize: Int?
        var hasPassphrase = false
        var requiresUserPresence = false
        var createdAt = Date(timeIntervalSince1970: 0)
        var sortIndex = 0.0

        init(_ value: SSHKeyRef) {
            id = value.id
            label = value.label
            algorithm = value.algorithm.rawValue
            publicKey = value.publicKey
            certificate = value.certificate
            fingerprint = value.fingerprint
            credentialRef = value.credentialRef
            storage = value.storage.rawValue
            keySize = value.keySize
            hasPassphrase = value.hasPassphrase
            requiresUserPresence = value.requiresUserPresence
            createdAt = value.createdAt
            sortIndex = value.sortIndex
        }
    }
}

enum TermindSchemaV7Models {
    @Model
    final class PersistentIdentity {
        @Attribute(.unique) var id: UUID = UUID()
        var name = ""
        var username = ""
        var credentialRef = ""
        var passwordStorage = PasswordStorage.iCloud.rawValue
        var keyID: UUID?
        var notes = ""
        var lastUsedAt: Date?
        var colorTag = TagColor.none.rawValue
        var sortIndex = 0.0

        init(_ value: Identity) {
            id = value.id
            apply(value)
        }

        func apply(_ value: Identity) {
            name = value.name
            username = value.username
            credentialRef = value.credentialRef
            passwordStorage = value.passwordStorage.rawValue
            keyID = value.keyID
            notes = value.notes
            lastUsedAt = value.lastUsedAt
            colorTag = value.colorTag.rawValue
            sortIndex = value.sortIndex
        }

        var value: Identity {
            Identity(
                id: id, name: name, username: username, credentialRef: credentialRef,
                passwordStorage: PasswordStorage(rawValue: passwordStorage) ?? .iCloud,
                keyID: keyID, notes: notes, lastUsedAt: lastUsedAt,
                colorTag: TagColor(rawValue: colorTag) ?? .none, sortIndex: sortIndex
            )
        }
    }

    @Model
    final class PersistentSSHKey {
        @Attribute(.unique) var id: UUID = UUID()
        var label = ""
        var algorithm = SSHKeyAlgorithm.ed25519.rawValue
        var publicKey = ""
        var certificate = ""
        var fingerprint = ""
        var credentialRef = ""
        var storage = KeyStorage.iCloud.rawValue
        var keySize: Int?
        var hasPassphrase = false
        var requiresUserPresence = false
        var createdAt = Date(timeIntervalSince1970: 0)
        var colorTag = TagColor.none.rawValue
        var sortIndex = 0.0

        init(_ value: SSHKeyRef) {
            id = value.id
            apply(value)
        }

        func apply(_ value: SSHKeyRef) {
            label = value.label
            algorithm = value.algorithm.rawValue
            publicKey = value.publicKey
            certificate = value.certificate
            fingerprint = value.fingerprint
            credentialRef = value.credentialRef
            storage = value.storage.rawValue
            keySize = value.keySize
            hasPassphrase = value.hasPassphrase
            requiresUserPresence = value.requiresUserPresence
            createdAt = value.createdAt
            colorTag = value.colorTag.rawValue
            sortIndex = value.sortIndex
        }

        var value: SSHKeyRef {
            SSHKeyRef(
                id: id, label: label,
                algorithm: SSHKeyAlgorithm(rawValue: algorithm) ?? .ed25519,
                publicKey: publicKey, certificate: certificate, fingerprint: fingerprint,
                credentialRef: credentialRef,
                storage: KeyStorage(rawValue: storage) ?? .iCloud,
                keySize: keySize, hasPassphrase: hasPassphrase,
                requiresUserPresence: requiresUserPresence, createdAt: createdAt,
                colorTag: TagColor(rawValue: colorTag) ?? .none, sortIndex: sortIndex
            )
        }
    }
}

typealias PersistentIdentity = TermindSchemaV7Models.PersistentIdentity
typealias PersistentSSHKey = TermindSchemaV7Models.PersistentSSHKey

@Model
final class PersistentKnownHost {
    @Attribute(.unique) var id: UUID = UUID()
    var hostname = ""
    var port = 22
    var algorithm = SSHKeyAlgorithm.ed25519.rawValue
    var fingerprint = ""
    var addedAt = Date(timeIntervalSince1970: 0)
    var isMismatched = false

    init(_ value: KnownHostEntry) {
        id = value.id
        apply(value)
    }

    func apply(_ value: KnownHostEntry) {
        hostname = value.hostname
        port = value.port
        algorithm = value.algorithm.rawValue
        fingerprint = value.fingerprint
        addedAt = value.addedAt
        isMismatched = value.isMismatched
    }

    var value: KnownHostEntry {
        KnownHostEntry(
            id: id, hostname: hostname, port: port,
            algorithm: SSHKeyAlgorithm(rawValue: algorithm) ?? .ed25519,
            fingerprint: fingerprint, addedAt: addedAt, isMismatched: isMismatched
        )
    }
}

@Model
final class PersistentPortForwardingRule {
    @Attribute(.unique) var id: UUID = UUID()
    var hostID: UUID = UUID()
    var kind = PortForwardingRule.Kind.local.rawValue
    var bindHost = "127.0.0.1"
    var bindPort = 8080
    var targetHost: String?
    var targetPort: Int?
    var label = ""

    init(_ value: PortForwardingRule) {
        id = value.id
        apply(value)
    }

    func apply(_ value: PortForwardingRule) {
        hostID = value.hostID
        kind = value.kind.rawValue
        bindHost = value.bindHost
        bindPort = value.bindPort
        targetHost = value.kind == .dynamic ? nil : value.targetHost
        targetPort = value.kind == .dynamic ? nil : value.targetPort
        label = value.label
    }

    var value: PortForwardingRule {
        PortForwardingRule(
            id: id, hostID: hostID,
            kind: PortForwardingRule.Kind(rawValue: kind) ?? .local,
            bindHost: bindHost, bindPort: bindPort,
            targetHost: targetHost, targetPort: targetPort, label: label
        )
    }
}

enum TermindSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            TermindSchemaV7HostModels.PersistentHost.self,
            PersistentHostGroup.self,
            TermindSchemaV6Models.PersistentIdentity.self,
            TermindSchemaV6Models.PersistentSSHKey.self,
            PersistentKnownHost.self,
            PersistentSnippetPackage.self,
            PersistentSnippet.self,
            PersistentPortForwardingRule.self,
            PersistentOutboxJob.self,
            PersistentPendingDeletion.self,
            PersistentDatabaseMetadata.self,
            TermindSchemaV9Models.PersistentCommandHistoryEntry.self,
            PersistentModelProvider.self,
            PersistentAIModel.self,
            PersistentAIRoleAssignment.self,
            PersistentAISelection.self,
            PersistentAgentConversation.self,
            PersistentAgentRun.self,
            PersistentAgentMessage.self,
            PersistentAgentToolInvocation.self,
            PersistentAgentToolResult.self,
            PersistentAgentReviewRecord.self,
            PersistentExternalToolCall.self,
            PersistentVaultSyncEntry.self,
            PersistentVaultSyncState.self,
            PersistentVaultSyncQuarantine.self,
        ]
    }
}

enum TermindSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        TermindSchemaV1.models + [PersistentMCPServer.self]
    }
}

enum TermindSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        TermindSchemaV2.models + [PersistentAgentContextAttachments.self]
    }
}

enum TermindSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        TermindSchemaV3.models + [PersistentSFTPHistoryEntry.self]
    }
}

enum TermindSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static var models: [any PersistentModel.Type] {
        TermindSchemaV4.models + [PersistentAgentConversationOrder.self]
    }
}

enum TermindSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)

    static var models: [any PersistentModel.Type] {
        TermindSchemaV5.models + [PersistentConnectionHistoryEntry.self]
    }
}

enum TermindSchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)

    static var models: [any PersistentModel.Type] {
        TermindSchemaV6.models.filter {
            $0 != TermindSchemaV6Models.PersistentIdentity.self
                && $0 != TermindSchemaV6Models.PersistentSSHKey.self
        } + [PersistentIdentity.self, PersistentSSHKey.self]
    }
}

enum TermindSchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)

    static var models: [any PersistentModel.Type] {
        TermindSchemaV7.models.filter {
            $0 != TermindSchemaV7HostModels.PersistentHost.self
        } + [PersistentHost.self]
    }
}

enum TermindSchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)

    static var models: [any PersistentModel.Type] {
        TermindSchemaV8.models + [PersistentAgentCompaction.self]
    }
}

enum TermindSchemaV10: VersionedSchema {
    static let versionIdentifier = Schema.Version(10, 0, 0)

    static var models: [any PersistentModel.Type] {
        TermindSchemaV9.models.filter {
            $0 != TermindSchemaV9Models.PersistentCommandHistoryEntry.self
        } + [PersistentCommandHistoryEntry.self]
    }
}

enum TermindSchemaV11: VersionedSchema {
    static let versionIdentifier = Schema.Version(11, 0, 0)

    static var models: [any PersistentModel.Type] {
        TermindSchemaV10.models + [PersistentAgentSkill.self]
    }
}

enum TermindMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            TermindSchemaV1.self, TermindSchemaV2.self, TermindSchemaV3.self,
            TermindSchemaV4.self, TermindSchemaV5.self, TermindSchemaV6.self,
            TermindSchemaV7.self, TermindSchemaV8.self, TermindSchemaV9.self,
            TermindSchemaV10.self, TermindSchemaV11.self,
        ]
    }

    static var stages: [MigrationStage] {
        [
            MigrationStage.lightweight(
                fromVersion: TermindSchemaV1.self, toVersion: TermindSchemaV2.self
            ),
            MigrationStage.lightweight(
                fromVersion: TermindSchemaV2.self, toVersion: TermindSchemaV3.self
            ),
            MigrationStage.lightweight(
                fromVersion: TermindSchemaV3.self, toVersion: TermindSchemaV4.self
            ),
            MigrationStage.lightweight(
                fromVersion: TermindSchemaV4.self, toVersion: TermindSchemaV5.self
            ),
            MigrationStage.custom(
                fromVersion: TermindSchemaV5.self, toVersion: TermindSchemaV6.self,
                willMigrate: nil,
                didMigrate: { context in
                    for host in try context.fetch(
                        FetchDescriptor<TermindSchemaV7HostModels.PersistentHost>()
                    ) {
                        host.lastUsedAt = nil
                    }
                    try context.save()
                }
            ),
            MigrationStage.lightweight(
                fromVersion: TermindSchemaV6.self, toVersion: TermindSchemaV7.self
            ),
            MigrationStage.lightweight(
                fromVersion: TermindSchemaV7.self, toVersion: TermindSchemaV8.self
            ),
            MigrationStage.lightweight(
                fromVersion: TermindSchemaV8.self, toVersion: TermindSchemaV9.self
            ),
            MigrationStage.lightweight(
                fromVersion: TermindSchemaV9.self, toVersion: TermindSchemaV10.self
            ),
            MigrationStage.lightweight(
                fromVersion: TermindSchemaV10.self, toVersion: TermindSchemaV11.self
            ),
        ]
    }
}

@MainActor
final class HostPersistence {
    static let schema = Schema(versionedSchema: TermindSchemaV11.self)

    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func load() throws -> VaultSnapshot {
        let snapshot = try fetchSnapshot()
        _ = try VaultSyncJournal(context: context).bootstrapIfNeeded(snapshot)
        if context.hasChanges { try context.save() }
        return snapshot
    }

    private func fetchSnapshot() throws -> VaultSnapshot {
        let hosts = try context.fetch(FetchDescriptor<PersistentHost>()).map(\.value)
        let groups = try context.fetch(FetchDescriptor<PersistentHostGroup>()).map(\.value)
        let identities = try context.fetch(FetchDescriptor<PersistentIdentity>()).map(\.value)
        let keys = try context.fetch(FetchDescriptor<PersistentSSHKey>()).map(\.value)
        let knownHosts = try context.fetch(FetchDescriptor<PersistentKnownHost>()).map(\.value)
        let snippets = try context.fetch(FetchDescriptor<PersistentSnippet>()).map(\.value)
        let snippetPackages = try context.fetch(FetchDescriptor<PersistentSnippetPackage>()).map(\.value)
        let portForwardings = try context.fetch(FetchDescriptor<PersistentPortForwardingRule>()).map(\.value)
        return VaultSnapshot(
            hosts: hosts, groups: groups, identities: identities, keys: keys,
            knownHosts: knownHosts, snippets: snippets,
            snippetPackages: snippetPackages, portForwardings: portForwardings
        )
    }

    func save(_ snapshot: VaultSnapshot) throws -> VaultMutationSet {
        do {
            let oldSnapshot = try fetchSnapshot()
            let journal = VaultSyncJournal(context: context)
            _ = try journal.bootstrapIfNeeded(oldSnapshot)
            let mutations = try journal.recordLocalChanges(from: oldSnapshot, to: snapshot)
            try persist(snapshot)
            try context.save()
            return mutations
        } catch {
            context.rollback()
            throw error
        }
    }

    func applyRemote(_ envelopes: [VaultEnvelope]) throws -> VaultRemoteApplyResult {
        do {
            let journal = VaultSyncJournal(context: context)
            let decision = try journal.mergeDecision(for: envelopes)
            var snapshot = try fetchSnapshot()
            for envelope in decision.accepted { try snapshot.apply(envelope) }
            try persist(snapshot)
            try journal.acceptRemote(decision.accepted)
            try journal.markNeedsUpload(decision.needsUpload)
            try context.save()
            return VaultRemoteApplyResult(
                snapshot: snapshot,
                acceptedKeys: Set(decision.accepted.map(\.key)),
                needsUpload: decision.needsUpload
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    func recordExternalMutation() throws -> VaultMutationSet {
        let snapshot = try fetchSnapshot()
        let journal = VaultSyncJournal(context: context)
        _ = try journal.bootstrapIfNeeded(snapshot)
        return try journal.recordCurrentSnapshot(snapshot)
    }

    private func persist(_ snapshot: VaultSnapshot) throws {
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentHost>()), with: snapshot.hosts,
            rowID: \.id, valueID: \.id,
            make: PersistentHost.init, apply: { $0.apply($1) }
        )
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentHostGroup>()), with: snapshot.groups,
            rowID: \.id, valueID: \.id,
            make: PersistentHostGroup.init, apply: { $0.apply($1) }
        )
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentIdentity>()), with: snapshot.identities,
            rowID: \.id, valueID: \.id,
            make: PersistentIdentity.init, apply: { $0.apply($1) }
        )
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentSSHKey>()), with: snapshot.keys,
            rowID: \.id, valueID: \.id,
            make: PersistentSSHKey.init, apply: { $0.apply($1) }
        )
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentKnownHost>()), with: snapshot.knownHosts,
            rowID: \.id, valueID: \.id,
            make: PersistentKnownHost.init, apply: { $0.apply($1) }
        )
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentSnippet>()), with: snapshot.snippets,
            rowID: \.id, valueID: \.id,
            make: PersistentSnippet.init, apply: { $0.apply($1) }
        )
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentSnippetPackage>()),
            with: snapshot.snippetPackages, rowID: \.id, valueID: \.id,
            make: PersistentSnippetPackage.init, apply: { $0.apply($1) }
        )
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentPortForwardingRule>()),
            with: snapshot.portForwardings, rowID: \.id, valueID: \.id,
            make: PersistentPortForwardingRule.init, apply: { $0.apply($1) }
        )
    }

    private func reconcile<Model: PersistentModel, Value>(
        _ rows: [Model], with values: [Value],
        rowID: (Model) -> UUID, valueID: (Value) -> UUID,
        make: (Value) -> Model, apply: (Model, Value) -> Void
    ) throws {
        var byID: [UUID: Model] = [:]
        for row in rows {
            let id = rowID(row)
            if byID[id] == nil { byID[id] = row } else { context.delete(row) }
        }
        let wanted = Set(values.map(valueID))
        for row in byID.values where !wanted.contains(rowID(row)) { context.delete(row) }
        for value in values {
            if let row = byID[valueID(value)] { apply(row, value) } else { context.insert(make(value)) }
        }
    }
}

extension HostPersistence: VaultPersisting {}
