import Foundation
import SwiftData

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
    var colorTag = HostColor.none.rawValue
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
        lastUsedAt = value.lastUsedAt
        sortIndex = value.sortIndex
    }

    var value: Host {
        var host = Host(
            id: id, name: name, host: address, port: port,
            identityID: identityID, groupID: groupID, tags: tags,
            colorTag: HostColor(rawValue: colorTag) ?? .none,
            lastUsedAt: lastUsedAt, sortIndex: sortIndex
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

// The V3 and V4 versions of these two models intentionally live in their
// schema namespaces. Reusing the live model type for an older VersionedSchema
// changes that older schema's checksum whenever a field is added and makes a
// staged migration impossible.
enum TermindSchemaV3Models {
    @Model
    final class PersistentIdentity {
        @Attribute(.unique) var id: UUID = UUID()
        var name = ""
        var username = ""
        var credentialRef = ""
        var keyID: UUID?
        var notes = ""
        var lastUsedAt: Date?
        var sortIndex = 0.0

        init(_ value: Identity) {
            id = value.id
            name = value.name
            username = value.username
            credentialRef = value.credentialRef
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
        var fingerprint = ""
        var credentialRef = ""
        var storage = "local" + "Keychain"
        var keySize: Int?
        var hasPassphrase = false
        var storesPassphrase = false
        var requiresUserPresence = false
        var createdAt = Date(timeIntervalSince1970: 0)
        var sortIndex = 0.0

        init(_ value: SSHKeyRef) {
            id = value.id
            label = value.label
            algorithm = value.algorithm.rawValue
            publicKey = value.publicKey
            fingerprint = value.fingerprint
            credentialRef = value.credentialRef
            storage = value.storage.rawValue
            keySize = value.keySize
            hasPassphrase = value.hasPassphrase
            storesPassphrase = value.storesPassphrase
            requiresUserPresence = value.requiresUserPresence
            createdAt = value.createdAt
            sortIndex = value.sortIndex
        }
    }
}

enum TermindSchemaV4Models {
    @Model
    final class PersistentIdentity {
        @Attribute(.unique) var id: UUID = UUID()
        var name = ""
        var username = ""
        var credentialRef = ""
        /// Rows created by older versions must continue to resolve the
        /// local-only Keychain item they already own.
        var passwordStorage = PasswordStorage.thisDevice.rawValue
        var keyID: UUID?
        var notes = ""
        var lastUsedAt: Date?
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
            sortIndex = value.sortIndex
        }

        var value: Identity {
            Identity(
                id: id, name: name, username: username, credentialRef: credentialRef,
                passwordStorage: PasswordStorage(rawValue: passwordStorage) ?? .thisDevice,
                keyID: keyID, notes: notes, lastUsedAt: lastUsedAt, sortIndex: sortIndex
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
        var storage = KeyStorage.thisDevice.rawValue
        var keySize: Int?
        var hasPassphrase = false
        var storesPassphrase = false
        var requiresUserPresence = false
        var createdAt = Date(timeIntervalSince1970: 0)
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
            storesPassphrase = value.storesPassphrase
            requiresUserPresence = value.requiresUserPresence
            createdAt = value.createdAt
            sortIndex = value.sortIndex
        }

        var value: SSHKeyRef {
            SSHKeyRef(
                id: id, label: label,
                algorithm: SSHKeyAlgorithm(rawValue: algorithm) ?? .ed25519,
                publicKey: publicKey, certificate: certificate, fingerprint: fingerprint,
                credentialRef: credentialRef,
                storage: KeyStorage(rawValue: storage) ?? .thisDevice,
                keySize: keySize, hasPassphrase: hasPassphrase,
                storesPassphrase: storesPassphrase,
                requiresUserPresence: requiresUserPresence, createdAt: createdAt,
                sortIndex: sortIndex
            )
        }
    }
}

typealias PersistentIdentity = TermindSchemaV4Models.PersistentIdentity
typealias PersistentSSHKey = TermindSchemaV4Models.PersistentSSHKey

@Model
final class PersistentKnownHost {
    @Attribute(.unique) var id: UUID = UUID()
    var hostname = ""
    var port = 22
    /// Kept under its original storage name so existing V1/V2 stores need no
    /// schema migration. The domain projection below exposes the typed
    /// `algorithm`; this raw string is only the compatibility boundary.
    var keyType = SSHKeyAlgorithm.ed25519.rawValue
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
        keyType = value.algorithm.rawValue
        fingerprint = value.fingerprint
        addedAt = value.addedAt
        isMismatched = value.isMismatched
    }

    var value: KnownHostEntry {
        KnownHostEntry(
            id: id, hostname: hostname, port: port,
            algorithm: SSHKeyAlgorithm(rawValue: keyType) ?? .ed25519,
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
            PersistentHost.self, PersistentHostGroup.self,
            TermindSchemaV3Models.PersistentIdentity.self,
            TermindSchemaV3Models.PersistentSSHKey.self,
            PersistentKnownHost.self, PersistentSnippetPackage.self,
            PersistentSnippet.self, PersistentPortForwardingRule.self,
        ]
    }
}

enum TermindSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        TermindSchemaV1.models + [
            PersistentOutboxJob.self,
            PersistentPendingDeletion.self,
            PersistentDatabaseMetadata.self,
        ]
    }
}

enum TermindSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        TermindSchemaV2.models + [PersistentCommandHistoryEntry.self]
    }
}

enum TermindSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        TermindSchemaV3.models.filter {
            $0 != TermindSchemaV3Models.PersistentIdentity.self
                && $0 != TermindSchemaV3Models.PersistentSSHKey.self
        } + [PersistentIdentity.self, PersistentSSHKey.self]
    }
}

enum TermindSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] {
        TermindSchemaV4.models + [
            PersistentModelProvider.self,
            PersistentAIModel.self,
            PersistentAIRoleAssignment.self,
            PersistentAISelection.self,
        ]
    }
}

enum TermindSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] {
        TermindSchemaV5.models + [
            PersistentAgentConversation.self,
            PersistentAgentRun.self,
            PersistentAgentMessage.self,
            PersistentAgentToolInvocation.self,
            PersistentAgentToolResult.self,
            PersistentAgentReviewRecord.self,
        ]
    }
}

enum TermindMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            TermindSchemaV1.self, TermindSchemaV2.self,
            TermindSchemaV3.self, TermindSchemaV4.self, TermindSchemaV5.self,
            TermindSchemaV6.self,
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: TermindSchemaV1.self,
                toVersion: TermindSchemaV2.self
            ),
            .lightweight(
                fromVersion: TermindSchemaV2.self,
                toVersion: TermindSchemaV3.self
            ),
            .custom(
                fromVersion: TermindSchemaV3.self,
                toVersion: TermindSchemaV4.self,
                willMigrate: nil,
                didMigrate: { context in
                    let legacyStorage = "local" + "Keychain"
                    let keys = try context.fetch(FetchDescriptor<PersistentSSHKey>())
                    for key in keys where key.storage == legacyStorage {
                        key.storage = KeyStorage.thisDevice.rawValue
                    }
                    let identities = try context.fetch(FetchDescriptor<PersistentIdentity>())
                    for identity in identities where identity.passwordStorage == legacyStorage {
                        identity.passwordStorage = PasswordStorage.thisDevice.rawValue
                    }
                    try context.save()
                }
            ),
            .lightweight(
                fromVersion: TermindSchemaV4.self,
                toVersion: TermindSchemaV5.self
            ),
            .lightweight(
                fromVersion: TermindSchemaV5.self,
                toVersion: TermindSchemaV6.self
            ),
        ]
    }
}

@MainActor
final class HostPersistence {
    static let schema = Schema(versionedSchema: TermindSchemaV6.self)

    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func load() throws -> (
        hosts: [Host], groups: [HostGroup], identities: [Identity],
        keys: [SSHKeyRef], knownHosts: [KnownHostEntry],
        snippets: [Snippet], snippetPackages: [SnippetPackage],
        portForwardings: [PortForwardingRule]
    ) {
        let hosts = try context.fetch(FetchDescriptor<PersistentHost>()).map(\.value)
        let groups = try context.fetch(FetchDescriptor<PersistentHostGroup>()).map(\.value)
        let identities = try context.fetch(FetchDescriptor<PersistentIdentity>()).map(\.value)
        let keys = try context.fetch(FetchDescriptor<PersistentSSHKey>()).map(\.value)
        let knownHosts = try context.fetch(FetchDescriptor<PersistentKnownHost>()).map(\.value)
        let snippets = try context.fetch(FetchDescriptor<PersistentSnippet>()).map(\.value)
        let snippetPackages = try context.fetch(FetchDescriptor<PersistentSnippetPackage>()).map(\.value)
        let portForwardings = try context.fetch(FetchDescriptor<PersistentPortForwardingRule>()).map(\.value)
        return (hosts, groups, identities, keys, knownHosts, snippets, snippetPackages, portForwardings)
    }

    func save(
        hosts: [Host], groups: [HostGroup], identities: [Identity],
        keys: [SSHKeyRef], knownHosts: [KnownHostEntry],
        snippets: [Snippet], snippetPackages: [SnippetPackage],
        portForwardings: [PortForwardingRule]
    ) throws {
        do {
            try replace(PersistentHost.self, with: hosts.map(PersistentHost.init))
            try replace(PersistentHostGroup.self, with: groups.map(PersistentHostGroup.init))
            try replace(PersistentIdentity.self, with: identities.map(PersistentIdentity.init))
            try replace(PersistentSSHKey.self, with: keys.map(PersistentSSHKey.init))
            try replace(PersistentKnownHost.self, with: knownHosts.map(PersistentKnownHost.init))
            try replace(PersistentSnippet.self, with: snippets.map(PersistentSnippet.init))
            try replace(
                PersistentSnippetPackage.self,
                with: snippetPackages.map(PersistentSnippetPackage.init)
            )
            try replace(
                PersistentPortForwardingRule.self,
                with: portForwardings.map(PersistentPortForwardingRule.init)
            )
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func replace<Model: PersistentModel>(_ type: Model.Type, with values: [Model]) throws {
        try context.delete(model: type)
        for value in values { context.insert(value) }
    }
}
