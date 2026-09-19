import Foundation
import SwiftData
import TermindDomain

import struct TermindDomain.Host

public enum TermindSchemaV7HostModels {
    @Model
    public final class PersistentHost {
        @Attribute(.unique) public var id: UUID = UUID()
        public var name = ""
        public var address = ""
        public var port = 22
        public var identityID: UUID?
        public var jumpHostID: UUID?
        public var proxyProtocol: String?
        public var proxyHostname = ""
        public var proxyPort = 0
        public var proxyUsername = ""
        public var proxyIdentityID: UUID?
        public var sftpSessionInitialPath = ""
        public var groupID: UUID?
        public var tags: [String] = []
        public var colorTag = TagColor.none.rawValue
        /// Legacy V1–V5 storage retained only so existing stores can migrate.
        /// Recents and last-connected presentation are derived from connection
        /// history; this column is never read or written by current code.
        public var lastUsedAt: Date?
        public var sortIndex = 0.0

        public init(_ value: Host) {
            id = value.id
            apply(value)
        }

        public func apply(_ value: Host) {
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

        public var value: Host {
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

public enum TermindSchemaV8Models {
    @Model
    public final class PersistentHost {
        @Attribute(.unique) public var id: UUID = UUID()
        public var name = ""
        public var address = ""
        public var port = 22
        public var identityID: UUID?
        public var jumpHostID: UUID?
        public var proxyProtocol: String?
        public var proxyHostname = ""
        public var proxyPort = 0
        public var proxyUsername = ""
        public var proxyIdentityID: UUID?
        public var sftpSessionInitialPath = ""
        public var groupID: UUID?
        public var tags: [String] = []
        public var colorTag = TagColor.none.rawValue
        public var detectedDistributionID: String?
        public var detectedDistributionLikeIDs: [String] = []
        /// Legacy storage retained for the existing V5–V6 migration contract.
        public var lastUsedAt: Date?
        public var sortIndex = 0.0

        public init(_ value: Host) {
            id = value.id
            apply(value)
        }

        public func apply(_ value: Host) {
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

        public var value: Host {
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

@Model
public final class PersistentHostGroup {
    @Attribute(.unique) public var id: UUID = UUID()
    public var name = ""
    public var parentID: UUID?
    public var sortIndex = 0.0
    public var isExpanded = true

    public init(_ value: HostGroup) {
        id = value.id
        apply(value)
    }

    public func apply(_ value: HostGroup) {
        name = value.name
        parentID = value.parentID
        sortIndex = value.sortIndex
        isExpanded = value.isExpanded
    }

    public var value: HostGroup {
        HostGroup(id: id, name: name, parentID: parentID, sortIndex: sortIndex, isExpanded: isExpanded)
    }
}

@Model
public final class PersistentSnippetPackage {
    @Attribute(.unique) public var id: UUID = UUID()
    public var name = ""
    public var parentID: UUID?
    public var sortIndex = 0.0
    public var isExpanded = true

    public init(_ value: SnippetPackage) {
        id = value.id
        apply(value)
    }

    public func apply(_ value: SnippetPackage) {
        name = value.name
        parentID = value.parentID
        sortIndex = value.sortIndex
        isExpanded = value.isExpanded
    }

    public var value: SnippetPackage {
        SnippetPackage(
            id: id, name: name, parentID: parentID,
            sortIndex: sortIndex, isExpanded: isExpanded
        )
    }
}

@Model
public final class PersistentSnippet {
    @Attribute(.unique) public var id: UUID = UUID()
    public var title = ""
    public var body = ""
    public var packageID: UUID?
    public var targetHostIDs: [UUID] = []
    public var sortIndex = 0.0

    public init(_ value: Snippet) {
        id = value.id
        apply(value)
    }

    public func apply(_ value: Snippet) {
        title = value.title
        body = value.body
        packageID = value.packageID
        targetHostIDs = value.targetHostIDs
        sortIndex = value.sortIndex
    }

    public var value: Snippet {
        Snippet(
            id: id, title: title, body: body,
            packageID: packageID, targetHostIDs: targetHostIDs,
            sortIndex: sortIndex
        )
    }
}

/// The V1–V6 shapes are frozen here so adding color fields to the live models
/// does not rewrite the checksums of already-shipped schemas.
public enum TermindSchemaV6Models {
    @Model
    public final class PersistentIdentity {
        @Attribute(.unique) public var id: UUID = UUID()
        public var name = ""
        public var username = ""
        public var credentialRef = ""
        public var passwordStorage = PasswordStorage.iCloud.rawValue
        public var keyID: UUID?
        public var notes = ""
        public var lastUsedAt: Date?
        public var sortIndex = 0.0

        public init(_ value: Identity) {
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
    public final class PersistentSSHKey {
        @Attribute(.unique) public var id: UUID = UUID()
        public var label = ""
        public var algorithm = SSHKeyAlgorithm.ed25519.rawValue
        public var publicKey = ""
        public var certificate = ""
        public var fingerprint = ""
        public var credentialRef = ""
        public var storage = KeyStorage.iCloud.rawValue
        public var keySize: Int?
        public var hasPassphrase = false
        public var requiresUserPresence = false
        public var createdAt = Date(timeIntervalSince1970: 0)
        public var sortIndex = 0.0

        public init(_ value: SSHKeyRef) {
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

public enum TermindSchemaV7Models {
    @Model
    public final class PersistentIdentity {
        @Attribute(.unique) public var id: UUID = UUID()
        public var name = ""
        public var username = ""
        public var credentialRef = ""
        public var passwordStorage = PasswordStorage.iCloud.rawValue
        public var keyID: UUID?
        public var notes = ""
        public var lastUsedAt: Date?
        public var colorTag = TagColor.none.rawValue
        public var sortIndex = 0.0

        public init(_ value: Identity) {
            id = value.id
            apply(value)
        }

        public func apply(_ value: Identity) {
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

        public var value: Identity {
            Identity(
                id: id, name: name, username: username, credentialRef: credentialRef,
                passwordStorage: PasswordStorage(rawValue: passwordStorage) ?? .iCloud,
                keyID: keyID, notes: notes, lastUsedAt: lastUsedAt,
                colorTag: TagColor(rawValue: colorTag) ?? .none, sortIndex: sortIndex
            )
        }
    }

    @Model
    public final class PersistentSSHKey {
        @Attribute(.unique) public var id: UUID = UUID()
        public var label = ""
        public var algorithm = SSHKeyAlgorithm.ed25519.rawValue
        public var publicKey = ""
        public var certificate = ""
        public var fingerprint = ""
        public var credentialRef = ""
        public var storage = KeyStorage.iCloud.rawValue
        public var keySize: Int?
        public var hasPassphrase = false
        public var requiresUserPresence = false
        public var createdAt = Date(timeIntervalSince1970: 0)
        public var colorTag = TagColor.none.rawValue
        public var sortIndex = 0.0

        public init(_ value: SSHKeyRef) {
            id = value.id
            apply(value)
        }

        public func apply(_ value: SSHKeyRef) {
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

        public var value: SSHKeyRef {
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

@Model
public final class PersistentKnownHost {
    @Attribute(.unique) public var id: UUID = UUID()
    public var hostname = ""
    public var port = 22
    public var algorithm = SSHKeyAlgorithm.ed25519.rawValue
    public var fingerprint = ""
    public var addedAt = Date(timeIntervalSince1970: 0)
    public var isMismatched = false

    public init(_ value: KnownHostEntry) {
        id = value.id
        apply(value)
    }

    public func apply(_ value: KnownHostEntry) {
        hostname = value.hostname
        port = value.port
        algorithm = value.algorithm.rawValue
        fingerprint = value.fingerprint
        addedAt = value.addedAt
        isMismatched = value.isMismatched
    }

    public var value: KnownHostEntry {
        KnownHostEntry(
            id: id, hostname: hostname, port: port,
            algorithm: SSHKeyAlgorithm(rawValue: algorithm) ?? .ed25519,
            fingerprint: fingerprint, addedAt: addedAt, isMismatched: isMismatched
        )
    }
}

@Model
public final class PersistentPortForwardingRule {
    @Attribute(.unique) public var id: UUID = UUID()
    public var hostID: UUID = UUID()
    public var kind = PortForwardingRule.Kind.local.rawValue
    public var bindHost = "127.0.0.1"
    public var bindPort = 8080
    public var targetHost: String?
    public var targetPort: Int?
    public var label = ""
    public var colorTag = TagColor.none.rawValue

    public init(_ value: PortForwardingRule) {
        id = value.id
        apply(value)
    }

    public func apply(_ value: PortForwardingRule) {
        hostID = value.hostID
        kind = value.kind.rawValue
        bindHost = value.bindHost
        bindPort = value.bindPort
        targetHost = value.kind == .dynamic ? nil : value.targetHost
        targetPort = value.kind == .dynamic ? nil : value.targetPort
        label = value.label
        colorTag = value.colorTag.rawValue
    }

    public var value: PortForwardingRule {
        PortForwardingRule(
            id: id, hostID: hostID,
            kind: PortForwardingRule.Kind(rawValue: kind) ?? .local,
            bindHost: bindHost, bindPort: bindPort,
            targetHost: targetHost, targetPort: targetPort, label: label,
            colorTag: TagColor(rawValue: colorTag) ?? .none
        )
    }
}

@Model
public final class PersistentWorkspaceTemplate {
    @Attribute(.unique) public var id: UUID = UUID()
    public var name = ""
    public var layoutData = Data()

    public init(_ value: WorkspaceTemplate) throws {
        id = value.id
        try apply(value)
    }

    public func apply(_ value: WorkspaceTemplate) throws {
        guard value.isValid else { throw WorkspaceTemplatePersistenceError.invalidTemplate(value.id) }
        name = value.name
        layoutData = try JSONEncoder().encode(value.layout)
    }

    public func value() throws -> WorkspaceTemplate {
        let value = WorkspaceTemplate(
            id: id,
            name: name,
            layout: try JSONDecoder().decode(WorkspaceTemplateLayout.self, from: layoutData)
        )
        guard value.isValid else { throw WorkspaceTemplatePersistenceError.invalidTemplate(id) }
        return value
    }
}

public nonisolated enum WorkspaceTemplatePersistenceError: LocalizedError {
    case invalidTemplate(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidTemplate:
            String(localized: "The Workspace template is invalid.")
        }
    }
}

public enum TermindSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            TermindSchemaV7HostModels.PersistentHost.self,
            PersistentHostGroup.self,
            TermindSchemaV6Models.PersistentIdentity.self,
            TermindSchemaV6Models.PersistentSSHKey.self,
            PersistentKnownHost.self,
            PersistentSnippetPackage.self,
            PersistentSnippet.self,
            TermindSchemaV19ForwardingModels.PersistentPortForwardingRule.self,
            PersistentOutboxJob.self,
            PersistentPendingDeletion.self,
            PersistentDatabaseMetadata.self,
            TermindSchemaV9Models.PersistentCommandHistoryEntry.self,
            TermindSchemaV11Models.PersistentModelProvider.self,
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

public enum TermindSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)

    public static var models: [any PersistentModel.Type] {
        TermindSchemaV1.models + [PersistentMCPServer.self]
    }
}

public enum TermindSchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)

    public static var models: [any PersistentModel.Type] {
        TermindSchemaV2.models + [PersistentAgentContextAttachments.self]
    }
}

public enum TermindSchemaV4: VersionedSchema {
    public static let versionIdentifier = Schema.Version(4, 0, 0)

    public static var models: [any PersistentModel.Type] {
        TermindSchemaV3.models + [PersistentSFTPHistoryEntry.self]
    }
}

public enum TermindSchemaV5: VersionedSchema {
    public static let versionIdentifier = Schema.Version(5, 0, 0)

    public static var models: [any PersistentModel.Type] {
        TermindSchemaV4.models + [PersistentAgentConversationOrder.self]
    }
}

public enum TermindSchemaV6: VersionedSchema {
    public static let versionIdentifier = Schema.Version(6, 0, 0)

    public static var models: [any PersistentModel.Type] {
        TermindSchemaV5.models + [PersistentConnectionHistoryEntry.self]
    }
}

public enum TermindSchemaV7: VersionedSchema {
    public static let versionIdentifier = Schema.Version(7, 0, 0)

    public static var models: [any PersistentModel.Type] {
        TermindSchemaV6.models.filter {
            $0 != TermindSchemaV6Models.PersistentIdentity.self
                && $0 != TermindSchemaV6Models.PersistentSSHKey.self
        } + [PersistentIdentity.self, PersistentSSHKey.self]
    }
}

public enum TermindSchemaV8: VersionedSchema {
    public static let versionIdentifier = Schema.Version(8, 0, 0)

    public static var models: [any PersistentModel.Type] {
        TermindSchemaV7.models.filter {
            $0 != TermindSchemaV7HostModels.PersistentHost.self
        } + [TermindSchemaV8Models.PersistentHost.self]
    }
}

public enum TermindSchemaV9: VersionedSchema {
    public static let versionIdentifier = Schema.Version(9, 0, 0)

    public static var models: [any PersistentModel.Type] {
        TermindSchemaV8.models + [PersistentAgentCompaction.self]
    }
}

public enum TermindSchemaV10: VersionedSchema {
    public static let versionIdentifier = Schema.Version(10, 0, 0)

    public static var models: [any PersistentModel.Type] {
        TermindSchemaV9.models.filter {
            $0 != TermindSchemaV9Models.PersistentCommandHistoryEntry.self
        } + [PersistentCommandHistoryEntry.self]
    }
}

public enum TermindSchemaV11: VersionedSchema {
    public static let versionIdentifier = Schema.Version(11, 0, 0)

    public static var models: [any PersistentModel.Type] {
        TermindSchemaV10.models + [PersistentAgentSkill.self]
    }
}

/// `PersistentModelProvider` trades its vendor-named kind and split address for
/// one API type and one URL, and drops the Vertex columns.
///
/// The stage is lightweight: `apiType` and `typedURL` arrive with defaults, and
/// the Vertex columns go away. What the old columns *meant* is recovered on
/// read by `PersistentModelProvider.legacyFold`, which is why `kind`,
/// `baseURL`, `apiPath` and `usesResponsesAPI` are still declared on the live
/// model — dropping them here would discard the addresses they encode before
/// anything had a chance to fold them.
///
/// A version has to differ from the one before it to be a version at all, and
/// two schemas built from the same live types hash identically. Hence
/// `TermindSchemaV11Models` — see the note there.
public enum TermindSchemaV12: VersionedSchema {
    public static let versionIdentifier = Schema.Version(12, 0, 0)

    public static var models: [any PersistentModel.Type] {
        TermindSchemaV11.models.filter {
            $0 != TermindSchemaV11Models.PersistentModelProvider.self
        } + [PersistentModelProvider.self]
    }
}

// V13 has already opened user stores. Preserve these entity names and defaults.
public enum TermindSchemaV13: VersionedSchema {
    public static let versionIdentifier = Schema.Version(13, 0, 0)
    public static var models: [any PersistentModel.Type] {
        TermindSchemaV12.models + [
            PersistentAIConfigurationSyncEntry.self, PersistentAIConfigurationSyncState.self,
            PersistentAIConfigurationSyncQuarantine.self, PersistentAIWebSearchPreferences.self,
            PersistentAISecretLocation.self,
        ]
    }
}

public enum TermindSchemaV14: VersionedSchema {
    public static let versionIdentifier = Schema.Version(14, 0, 0)
    public static var models: [any PersistentModel.Type] {
        TermindSchemaV13.models + [PersistentTerminalPreferences.self]
    }
}

public enum TermindSchemaV15: VersionedSchema {
    public static let versionIdentifier = Schema.Version(15, 0, 0)
    public static var models: [any PersistentModel.Type] {
        TermindSchemaV14.models + [
            PersistentMetricsSyncEntry.self, PersistentMetricsSyncState.self,
            PersistentMetricsSyncQuarantine.self,
        ]
    }
}

public enum TermindSchemaV16: VersionedSchema {
    public static let versionIdentifier = Schema.Version(16, 0, 0)
    public static var models: [any PersistentModel.Type] {
        TermindSchemaV15.models + [PersistentAgentMessageReplay.self]
    }
}

public enum TermindSchemaV17: VersionedSchema {
    public static let versionIdentifier = Schema.Version(17, 0, 0)
    public static var models: [any PersistentModel.Type] {
        TermindSchemaV16.models + [PersistentWorkspaceTemplate.self]
    }
}

public enum TermindSchemaV18: VersionedSchema {
    public static let versionIdentifier = Schema.Version(18, 0, 0)
    public static var models: [any PersistentModel.Type] {
        TermindSchemaV17.models + [PersistentSkillPackage.self]
    }
}

public enum TermindSchemaV19: VersionedSchema {
    public static let versionIdentifier = Schema.Version(19, 0, 0)
    public static var models: [any PersistentModel.Type] {
        TermindSchemaV18.models + [PersistentModelProviderVertexConfiguration.self]
    }
}

public enum TermindSchemaV20: VersionedSchema {
    public static let versionIdentifier = Schema.Version(20, 0, 0)
    public static var models: [any PersistentModel.Type] {
        TermindSchemaV19.models.filter {
            $0 != TermindSchemaV19ForwardingModels.PersistentPortForwardingRule.self
        } + [PersistentPortForwardingRule.self]
    }
}

public enum TermindSchemaV21: VersionedSchema {
    public static let versionIdentifier = Schema.Version(21, 0, 0)
    public static var models: [any PersistentModel.Type] {
        TermindSchemaV20.models + [PersistentSFTPPreferences.self]
    }
}

public enum TermindSchemaV22: VersionedSchema {
    public static let versionIdentifier = Schema.Version(22, 0, 0)
    public static var models: [any PersistentModel.Type] {
        TermindSchemaV21.models.filter {
            $0 != TermindSchemaV8Models.PersistentHost.self
        } + [PersistentHost.self]
    }
}

public enum TermindSchemaV23: VersionedSchema {
    public static let versionIdentifier = Schema.Version(23, 0, 0)
    public static var models: [any PersistentModel.Type] {
        TermindSchemaV22.models + [PersistentSSHPreferences.self]
    }
}

public enum TermindMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [
            TermindSchemaV1.self, TermindSchemaV2.self, TermindSchemaV3.self,
            TermindSchemaV4.self, TermindSchemaV5.self, TermindSchemaV6.self,
            TermindSchemaV7.self, TermindSchemaV8.self, TermindSchemaV9.self,
            TermindSchemaV10.self, TermindSchemaV11.self, TermindSchemaV12.self, TermindSchemaV13.self,
            TermindSchemaV14.self, TermindSchemaV15.self, TermindSchemaV16.self, TermindSchemaV17.self,
            TermindSchemaV18.self, TermindSchemaV19.self, TermindSchemaV20.self, TermindSchemaV21.self,
            TermindSchemaV22.self, TermindSchemaV23.self,
        ]
    }

    public static var stages: [MigrationStage] {
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
            MigrationStage.lightweight(
                fromVersion: TermindSchemaV11.self, toVersion: TermindSchemaV12.self
            ),
            MigrationStage.lightweight(
                fromVersion: TermindSchemaV12.self, toVersion: TermindSchemaV13.self
            ),
            MigrationStage.lightweight(
                fromVersion: TermindSchemaV13.self, toVersion: TermindSchemaV14.self
            ),
            MigrationStage.lightweight(
                fromVersion: TermindSchemaV14.self, toVersion: TermindSchemaV15.self
            ),
            MigrationStage.lightweight(fromVersion: TermindSchemaV15.self, toVersion: TermindSchemaV16.self),
            MigrationStage.lightweight(fromVersion: TermindSchemaV16.self, toVersion: TermindSchemaV17.self),
            MigrationStage.lightweight(fromVersion: TermindSchemaV17.self, toVersion: TermindSchemaV18.self),
            MigrationStage.lightweight(fromVersion: TermindSchemaV18.self, toVersion: TermindSchemaV19.self),
            MigrationStage.lightweight(fromVersion: TermindSchemaV19.self, toVersion: TermindSchemaV20.self),
            MigrationStage.lightweight(fromVersion: TermindSchemaV20.self, toVersion: TermindSchemaV21.self),
            MigrationStage.lightweight(fromVersion: TermindSchemaV21.self, toVersion: TermindSchemaV22.self),
            MigrationStage.lightweight(fromVersion: TermindSchemaV22.self, toVersion: TermindSchemaV23.self),
        ]
    }
}

public typealias PersistentHost = TermindSchemaV22HostModels.PersistentHost
public typealias PersistentIdentity = TermindSchemaV7Models.PersistentIdentity
public typealias PersistentSSHKey = TermindSchemaV7Models.PersistentSSHKey
