import Foundation
import TermindDomain

/// Frozen V1 transport DTOs. Do not add fields/cases here when domain models evolve.
/// Add a V2 DTO and register a decoder for the affected kind instead. Explicit
/// adapters are intentional: a new domain property must never silently change V1.
/// Names, optional omission, associated-value labels and legacy decode defaults
/// are part of the shipped JSON contract, including the synthesized `_0` wrappers.
nonisolated enum VaultWireV1 {
    enum TagColor: String, Codable {
        case none, red, orange, yellow, green, teal, blue, purple, pink
    }
    enum RemoteCharset: String, Codable {
        case utf8
        case gb18030
        case big5
        case shiftJIS
        case eucJP
        case eucKR
        case isoLatin1
        case windows1252
    }
    enum HostShellIntegrationMode: String, Codable {
        case followGlobalSettings
        case enabled
        case disabled
    }
    enum PasswordStorage: String, Codable {
        case thisDevice
        case iCloud
    }
    enum HostCustomIdentityPurpose: String, Codable {
        case ssh
        case telnet
        case proxy
        case telnetProxy
    }
    enum KeyStorage: String, Codable {
        case thisDevice
        case iCloud
        case secureEnclave
    }
    enum SSHKeyAlgorithm: String, Codable {
        case ed25519 = "ssh-ed25519"
        case ecdsa256 = "ecdsa-sha2-nistp256"
        case ecdsa384 = "ecdsa-sha2-nistp384"
        case ecdsa521 = "ecdsa-sha2-nistp521"
        case rsa = "ssh-rsa"
    }
    struct Host: Codable, Identifiable {
        static let defaultPortForwardingMaxConnections = 1
        static let portForwardingMaxConnectionsRange = 1...64
        var id: UUID = UUID()
        var name: String
        var host: String
        var sshEnabled = true
        var sshPort: Int = 22
        var sshIdentityID: Identity.ID?
        var sshCharset: RemoteCharset = .utf8
        var telnetEnabled = false
        var telnetPort: Int = 23
        var telnetIdentityID: Identity.ID?
        var telnetCharset: RemoteCharset = .utf8
        var telnetProxy: HostProxy?
        var jumpHostID: Host.ID?
        var proxy: HostProxy?
        var sftpChannelInitialPath: String = ""
        var groupID: HostGroup.ID?
        var tags: [String] = []
        var colorTag: TagColor = .none
        var shellIntegrationMode: HostShellIntegrationMode = .followGlobalSettings
        var startupSnippetID: Snippet.ID?
        var environmentVariables: [HostEnvironmentVariable] = []
        var portForwardingMaxConnections: Int = Self.defaultPortForwardingMaxConnections
        var detectedDistribution: DetectedDistribution?
        var sortIndex: Double = 0
        private enum CodingKeys: String, CodingKey {
            case id, name, host, port, identityID, jumpHostID, proxy
            case sftpChannelInitialPath = "sftpSessionInitialPath"
            case charset
            case sshEnabled, telnetEnabled, telnetPort, telnetIdentityID, telnetCharset, telnetProxy
            case groupID, tags, colorTag, detectedDistribution, sortIndex, shellIntegrationMode
            case startupSnippetID, environmentVariables, portForwardingMaxConnections
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            name = try values.decode(String.self, forKey: .name)
            host = try values.decode(String.self, forKey: .host)
            sshEnabled = try values.decodeIfPresent(Bool.self, forKey: .sshEnabled) ?? true
            sshPort = try values.decode(Int.self, forKey: .port)
            sshIdentityID = try values.decodeIfPresent(UUID.self, forKey: .identityID)
            telnetEnabled = try values.decodeIfPresent(Bool.self, forKey: .telnetEnabled) ?? false
            telnetPort = try values.decodeIfPresent(Int.self, forKey: .telnetPort) ?? 23
            telnetIdentityID = try values.decodeIfPresent(UUID.self, forKey: .telnetIdentityID)
            telnetProxy = try values.decodeIfPresent(HostProxy.self, forKey: .telnetProxy)
            telnetCharset =
                try values.decodeIfPresent(RemoteCharset.self, forKey: .telnetCharset) ?? .utf8
            jumpHostID = try values.decodeIfPresent(UUID.self, forKey: .jumpHostID)
            proxy = try values.decodeIfPresent(HostProxy.self, forKey: .proxy)
            sftpChannelInitialPath = try values.decode(String.self, forKey: .sftpChannelInitialPath)
            sshCharset =
                try values.decodeIfPresent(RemoteCharset.self, forKey: .charset) ?? .utf8
            groupID = try values.decodeIfPresent(UUID.self, forKey: .groupID)
            tags = try values.decode([String].self, forKey: .tags)
            colorTag = try values.decode(TagColor.self, forKey: .colorTag)
            detectedDistribution = try values.decodeIfPresent(DetectedDistribution.self, forKey: .detectedDistribution)
            sortIndex = try values.decode(Double.self, forKey: .sortIndex)
            shellIntegrationMode =
                try values.decodeIfPresent(HostShellIntegrationMode.self, forKey: .shellIntegrationMode)
                ?? .followGlobalSettings
            startupSnippetID = try values.decodeIfPresent(Snippet.ID.self, forKey: .startupSnippetID)
            environmentVariables =
                try values.decodeIfPresent([HostEnvironmentVariable].self, forKey: .environmentVariables) ?? []
            portForwardingMaxConnections = Self.normalizedPortForwardingMaxConnections(
                try values.decodeIfPresent(Int.self, forKey: .portForwardingMaxConnections)
                    ?? Self.defaultPortForwardingMaxConnections)
        }
        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(name, forKey: .name)
            try values.encode(host, forKey: .host)
            try values.encode(sshPort, forKey: .port)
            try values.encodeIfPresent(sshIdentityID, forKey: .identityID)
            try values.encodeIfPresent(jumpHostID, forKey: .jumpHostID)
            try values.encodeIfPresent(proxy, forKey: .proxy)
            try values.encode(sftpChannelInitialPath, forKey: .sftpChannelInitialPath)
            try values.encode(sshCharset.rawValue, forKey: .charset)
            try values.encode(sshEnabled, forKey: .sshEnabled)
            try values.encode(telnetEnabled, forKey: .telnetEnabled)
            try values.encode(telnetPort, forKey: .telnetPort)
            try values.encodeIfPresent(telnetIdentityID, forKey: .telnetIdentityID)
            try values.encode(telnetCharset.rawValue, forKey: .telnetCharset)
            try values.encodeIfPresent(telnetProxy, forKey: .telnetProxy)
            try values.encodeIfPresent(groupID, forKey: .groupID)
            try values.encode(tags, forKey: .tags)
            try values.encode(colorTag, forKey: .colorTag)
            try values.encodeIfPresent(detectedDistribution, forKey: .detectedDistribution)
            try values.encode(sortIndex, forKey: .sortIndex)
            try values.encode(shellIntegrationMode.rawValue, forKey: .shellIntegrationMode)
            try values.encodeIfPresent(startupSnippetID, forKey: .startupSnippetID)
            try values.encode(environmentVariables, forKey: .environmentVariables)
            try values.encode(portForwardingMaxConnections, forKey: .portForwardingMaxConnections)
        }
        static func normalizedPortForwardingMaxConnections(_ value: Int) -> Int {
            min(max(value, portForwardingMaxConnectionsRange.lowerBound), portForwardingMaxConnectionsRange.upperBound)
        }
        init(_ value: TermindDomain.Host) {
            self.id = value.id
            self.name = value.name
            self.host = value.host
            self.sshEnabled = value.sshEnabled
            self.sshPort = value.sshPort
            self.sshIdentityID = value.sshIdentityID
            self.sshCharset = RemoteCharset(rawValue: value.sshCharset.rawValue)!
            self.telnetEnabled = value.telnetEnabled
            self.telnetPort = value.telnetPort
            self.telnetIdentityID = value.telnetIdentityID
            self.telnetCharset = RemoteCharset(rawValue: value.telnetCharset.rawValue)!
            self.telnetProxy = value.telnetProxy.map(HostProxy.init)
            self.jumpHostID = value.jumpHostID
            self.proxy = value.proxy.map(HostProxy.init)
            self.sftpChannelInitialPath = value.sftpChannelInitialPath
            self.groupID = value.groupID
            self.tags = value.tags
            self.colorTag = TagColor(rawValue: value.colorTag.rawValue)!
            self.shellIntegrationMode = HostShellIntegrationMode(rawValue: value.shellIntegrationMode.rawValue)!
            self.startupSnippetID = value.startupSnippetID
            self.environmentVariables = value.environmentVariables.map { HostEnvironmentVariable($0) }
            self.portForwardingMaxConnections = value.portForwardingMaxConnections
            self.detectedDistribution = value.detectedDistribution.map(DetectedDistribution.init)
            self.sortIndex = value.sortIndex
        }
        var domainValue: TermindDomain.Host {
            var result = TermindDomain.Host(name: "", host: "", sessionPersistence: .init(enabled: false))
            result.id = id
            result.name = name
            result.host = host
            result.sshEnabled = sshEnabled
            result.sshPort = sshPort
            result.sshIdentityID = sshIdentityID
            result.sshCharset = TermindDomain.RemoteCharset(rawValue: sshCharset.rawValue)!
            result.telnetEnabled = telnetEnabled
            result.telnetPort = telnetPort
            result.telnetIdentityID = telnetIdentityID
            result.telnetCharset = TermindDomain.RemoteCharset(rawValue: telnetCharset.rawValue)!
            result.telnetProxy = telnetProxy?.domainValue
            result.jumpHostID = jumpHostID
            result.proxy = proxy?.domainValue
            result.sftpChannelInitialPath = sftpChannelInitialPath
            result.groupID = groupID
            result.tags = tags
            result.colorTag = TermindDomain.TagColor(rawValue: colorTag.rawValue)!
            result.shellIntegrationMode = TermindDomain.HostShellIntegrationMode(
                rawValue: shellIntegrationMode.rawValue)!
            result.startupSnippetID = startupSnippetID
            result.environmentVariables = environmentVariables.map { $0.domainValue }
            result.portForwardingMaxConnections = portForwardingMaxConnections
            result.detectedDistribution = detectedDistribution?.domainValue
            result.sortIndex = sortIndex
            return result
        }
    }
    struct HostGroup: Codable, Identifiable {
        var id: UUID = UUID()
        var name: String
        var parentID: HostGroup.ID?
        var sortIndex: Double = 0
        var isExpanded: Bool = true
        init(_ value: TermindDomain.HostGroup) {
            self.id = value.id
            self.name = value.name
            self.parentID = value.parentID
            self.sortIndex = value.sortIndex
            self.isExpanded = value.isExpanded
        }
        var domainValue: TermindDomain.HostGroup {
            var result = TermindDomain.HostGroup(name: "")
            result.id = id
            result.name = name
            result.parentID = parentID
            result.sortIndex = sortIndex
            result.isExpanded = isExpanded
            return result
        }
    }
    struct Identity: Codable, Identifiable {
        var id: UUID = UUID()
        var name: String
        var username: String
        var credentialRef: String = ""
        var passwordStorage: PasswordStorage = .iCloud
        var keyID: SSHKeyRef.ID?
        var notes: String = ""
        var colorTag: TagColor = .none
        var ownerHostID: UUID?
        var customPurpose: HostCustomIdentityPurpose?
        var sortIndex: Double = 0
        init(
            id: UUID = UUID(), name: String, username: String, credentialRef: String = "",
            passwordStorage: PasswordStorage = .iCloud, keyID: SSHKeyRef.ID? = nil, notes: String = "",
            colorTag: TagColor = .none, sortIndex: Double = 0,
            ownerHostID: UUID? = nil, customPurpose: HostCustomIdentityPurpose? = nil
        ) {
            self.id = id
            self.name = name
            self.username = username
            self.credentialRef = credentialRef
            self.passwordStorage = passwordStorage
            self.keyID = keyID
            self.notes = notes
            self.colorTag = colorTag
            self.sortIndex = sortIndex
            self.ownerHostID = ownerHostID
            self.customPurpose = customPurpose
        }
        private enum CodingKeys: String, CodingKey {
            case id, name, username, credentialRef, passwordStorage, keyID, notes
            case colorTag, sortIndex
            case ownerHostID, customPurpose
        }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                id: try container.decode(UUID.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                username: try container.decode(String.self, forKey: .username),
                credentialRef: try container.decode(String.self, forKey: .credentialRef),
                passwordStorage: try container.decode(PasswordStorage.self, forKey: .passwordStorage),
                keyID: try container.decodeIfPresent(SSHKeyRef.ID.self, forKey: .keyID),
                notes: try container.decode(String.self, forKey: .notes),
                colorTag: (try? container.decode(TagColor.self, forKey: .colorTag)) ?? .none,
                sortIndex: try container.decode(Double.self, forKey: .sortIndex),
                ownerHostID: try container.decodeIfPresent(UUID.self, forKey: .ownerHostID),
                customPurpose: try container.decodeIfPresent(HostCustomIdentityPurpose.self, forKey: .customPurpose)
            )
        }
        init(_ value: TermindDomain.Identity) {
            self.id = value.id
            self.name = value.name
            self.username = value.username
            self.credentialRef = value.credentialRef
            self.passwordStorage = PasswordStorage(rawValue: value.passwordStorage.rawValue)!
            self.keyID = value.keyID
            self.notes = value.notes
            self.colorTag = TagColor(rawValue: value.colorTag.rawValue)!
            self.ownerHostID = value.ownerHostID
            self.customPurpose = value.customPurpose.map { HostCustomIdentityPurpose(rawValue: $0.rawValue)! }
            self.sortIndex = value.sortIndex
        }
        var domainValue: TermindDomain.Identity {
            var result = TermindDomain.Identity(name: "", username: "")
            result.id = id
            result.name = name
            result.username = username
            result.credentialRef = credentialRef
            result.passwordStorage = TermindDomain.PasswordStorage(rawValue: passwordStorage.rawValue)!
            result.keyID = keyID
            result.notes = notes
            result.colorTag = TermindDomain.TagColor(rawValue: colorTag.rawValue)!
            result.ownerHostID = ownerHostID
            result.customPurpose = customPurpose.map { TermindDomain.HostCustomIdentityPurpose(rawValue: $0.rawValue)! }
            result.sortIndex = sortIndex
            return result
        }
    }
    struct SSHKeyRef: Codable, Identifiable {
        var id: UUID = UUID()
        var label: String
        var algorithm: SSHKeyAlgorithm = .ed25519
        var publicKey: String = ""
        var certificate: String = ""
        var fingerprint: String = ""
        var credentialRef: String = ""
        var storage: KeyStorage = .iCloud
        var keySize: Int?
        var hasPassphrase = false
        var requiresUserPresence = false
        var createdAt: Date = Date(timeIntervalSince1970: 0)
        var colorTag: TagColor = .none
        var sortIndex: Double = 0
        init(
            id: UUID = UUID(), label: String, algorithm: SSHKeyAlgorithm = .ed25519, publicKey: String = "",
            certificate: String = "", fingerprint: String = "", credentialRef: String = "",
            storage: KeyStorage = .iCloud,
            keySize: Int? = nil, hasPassphrase: Bool = false, requiresUserPresence: Bool = false,
            createdAt: Date = Date(timeIntervalSince1970: 0), colorTag: TagColor = .none, sortIndex: Double = 0
        ) {
            self.id = id
            self.label = label
            self.algorithm = algorithm
            self.publicKey = publicKey
            self.certificate = certificate
            self.fingerprint = fingerprint
            self.credentialRef = credentialRef
            self.storage = storage
            self.keySize = keySize
            self.hasPassphrase = hasPassphrase
            self.requiresUserPresence = requiresUserPresence
            self.createdAt = createdAt
            self.colorTag = colorTag
            self.sortIndex = sortIndex
        }
        private enum CodingKeys: String, CodingKey {
            case id, label, algorithm, publicKey, certificate, fingerprint
            case credentialRef, storage, keySize, hasPassphrase, requiresUserPresence
            case createdAt, colorTag, sortIndex
        }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                id: try container.decode(UUID.self, forKey: .id),
                label: try container.decode(String.self, forKey: .label),
                algorithm: try container.decode(SSHKeyAlgorithm.self, forKey: .algorithm),
                publicKey: try container.decode(String.self, forKey: .publicKey),
                certificate: try container.decode(String.self, forKey: .certificate),
                fingerprint: try container.decode(String.self, forKey: .fingerprint),
                credentialRef: try container.decode(String.self, forKey: .credentialRef),
                storage: try container.decode(KeyStorage.self, forKey: .storage),
                keySize: try container.decodeIfPresent(Int.self, forKey: .keySize),
                hasPassphrase: try container.decode(Bool.self, forKey: .hasPassphrase),
                requiresUserPresence: try container.decode(Bool.self, forKey: .requiresUserPresence),
                createdAt: try container.decode(Date.self, forKey: .createdAt),
                colorTag: (try? container.decode(TagColor.self, forKey: .colorTag)) ?? .none,
                sortIndex: try container.decode(Double.self, forKey: .sortIndex)
            )
        }
        init(_ value: TermindDomain.SSHKeyRef) {
            self.id = value.id
            self.label = value.label
            self.algorithm = SSHKeyAlgorithm(rawValue: value.algorithm.rawValue)!
            self.publicKey = value.publicKey
            self.certificate = value.certificate
            self.fingerprint = value.fingerprint
            self.credentialRef = value.credentialRef
            self.storage = KeyStorage(rawValue: value.storage.rawValue)!
            self.keySize = value.keySize
            self.hasPassphrase = value.hasPassphrase
            self.requiresUserPresence = value.requiresUserPresence
            self.createdAt = value.createdAt
            self.colorTag = TagColor(rawValue: value.colorTag.rawValue)!
            self.sortIndex = value.sortIndex
        }
        var domainValue: TermindDomain.SSHKeyRef {
            var result = TermindDomain.SSHKeyRef(label: "")
            result.id = id
            result.label = label
            result.algorithm = TermindDomain.SSHKeyAlgorithm(rawValue: algorithm.rawValue)!
            result.publicKey = publicKey
            result.certificate = certificate
            result.fingerprint = fingerprint
            result.credentialRef = credentialRef
            result.storage = TermindDomain.KeyStorage(rawValue: storage.rawValue)!
            result.keySize = keySize
            result.hasPassphrase = hasPassphrase
            result.requiresUserPresence = requiresUserPresence
            result.createdAt = createdAt
            result.colorTag = TermindDomain.TagColor(rawValue: colorTag.rawValue)!
            result.sortIndex = sortIndex
            return result
        }
    }
    struct KnownHostEntry: Codable, Identifiable {
        var id: UUID = UUID()
        var hostname: String
        var port: Int = 22
        var algorithm: SSHKeyAlgorithm = .ed25519
        var fingerprint: String = ""
        var addedAt: Date = Date(timeIntervalSince1970: 0)
        init(_ value: TermindDomain.KnownHostEntry) {
            self.id = value.id
            self.hostname = value.hostname
            self.port = value.port
            self.algorithm = SSHKeyAlgorithm(rawValue: value.algorithm.rawValue)!
            self.fingerprint = value.fingerprint
            self.addedAt = value.addedAt
        }
        var domainValue: TermindDomain.KnownHostEntry {
            var result = TermindDomain.KnownHostEntry(hostname: "")
            result.id = id
            result.hostname = hostname
            result.port = port
            result.algorithm = TermindDomain.SSHKeyAlgorithm(rawValue: algorithm.rawValue)!
            result.fingerprint = fingerprint
            result.addedAt = addedAt
            return result
        }
    }
    struct Snippet: Codable, Identifiable {
        var id: UUID = UUID()
        var title: String
        var body: String
        var packageID: SnippetPackage.ID?
        var targetHostIDs: [Host.ID] = []
        var sortIndex: Double = 0
        init(_ value: TermindDomain.Snippet) {
            self.id = value.id
            self.title = value.title
            self.body = value.body
            self.packageID = value.packageID
            self.targetHostIDs = value.targetHostIDs
            self.sortIndex = value.sortIndex
        }
        var domainValue: TermindDomain.Snippet {
            var result = TermindDomain.Snippet(title: "", body: "")
            result.id = id
            result.title = title
            result.body = body
            result.packageID = packageID
            result.targetHostIDs = targetHostIDs
            result.sortIndex = sortIndex
            return result
        }
    }
    struct SnippetPackage: Codable, Identifiable {
        var id: UUID = UUID()
        var name: String
        var parentID: SnippetPackage.ID?
        var sortIndex: Double = 0
        var isExpanded: Bool = true
        init(_ value: TermindDomain.SnippetPackage) {
            self.id = value.id
            self.name = value.name
            self.parentID = value.parentID
            self.sortIndex = value.sortIndex
            self.isExpanded = value.isExpanded
        }
        var domainValue: TermindDomain.SnippetPackage {
            var result = TermindDomain.SnippetPackage(name: "")
            result.id = id
            result.name = name
            result.parentID = parentID
            result.sortIndex = sortIndex
            result.isExpanded = isExpanded
            return result
        }
    }
    struct PortForwardingRule: Codable, Identifiable {
        enum Kind: String, Codable { case local, remote, dynamic }
        var id: UUID = UUID()
        var hostID: Host.ID
        var kind: Kind = .local
        var bindHost: String = "127.0.0.1"
        var bindPort: Int = 8080
        var targetHost: String? = "localhost"
        var targetPort: Int? = 80
        var label: String = ""
        var colorTag: TagColor = .none
        init(
            id: UUID = UUID(), hostID: Host.ID, kind: Kind = .local,
            bindHost: String = "127.0.0.1", bindPort: Int = 8080,
            targetHost: String? = "localhost", targetPort: Int? = 80,
            label: String = "", colorTag: TagColor = .none
        ) {
            self.id = id
            self.hostID = hostID
            self.kind = kind
            self.bindHost = bindHost
            self.bindPort = bindPort
            self.targetHost = kind == .dynamic ? nil : targetHost
            self.targetPort = kind == .dynamic ? nil : targetPort
            self.label = label
            self.colorTag = colorTag
        }
        private enum CodingKeys: String, CodingKey {
            case id, hostID, kind, bindHost, bindPort, targetHost, targetPort, label, colorTag
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                id: try values.decode(UUID.self, forKey: .id),
                hostID: try values.decode(UUID.self, forKey: .hostID),
                kind: try values.decode(Kind.self, forKey: .kind),
                bindHost: try values.decode(String.self, forKey: .bindHost),
                bindPort: try values.decode(Int.self, forKey: .bindPort),
                targetHost: try values.decodeIfPresent(String.self, forKey: .targetHost),
                targetPort: try values.decodeIfPresent(Int.self, forKey: .targetPort),
                label: try values.decode(String.self, forKey: .label),
                colorTag: (try? values.decode(TagColor.self, forKey: .colorTag)) ?? .none)
        }
        init(_ value: TermindDomain.PortForwardingRule) {
            self.id = value.id
            self.hostID = value.hostID
            self.kind = Kind(rawValue: value.kind.rawValue)!
            self.bindHost = value.bindHost
            self.bindPort = value.bindPort
            self.targetHost = value.targetHost
            self.targetPort = value.targetPort
            self.label = value.label
            self.colorTag = TagColor(rawValue: value.colorTag.rawValue)!
        }
        var domainValue: TermindDomain.PortForwardingRule {
            var result = TermindDomain.PortForwardingRule(hostID: hostID)
            result.id = id
            result.hostID = hostID
            result.kind = TermindDomain.PortForwardingRule.Kind(rawValue: kind.rawValue)!
            result.bindHost = bindHost
            result.bindPort = bindPort
            result.targetHost = targetHost
            result.targetPort = targetPort
            result.label = label
            result.colorTag = TermindDomain.TagColor(rawValue: colorTag.rawValue)!
            return result
        }
    }
    struct WorkspaceTemplate: Codable, Identifiable {
        var id: UUID
        var name: String
        var layout: WorkspaceTemplateLayout
        init(_ value: TermindDomain.WorkspaceTemplate) throws {
            self.id = value.id
            self.name = value.name
            self.layout = try WorkspaceTemplateLayout(value.layout)
        }
        var domainValue: TermindDomain.WorkspaceTemplate {
            var result = TermindDomain.WorkspaceTemplate(name: name, layout: layout.domainValue)
            result.id = id
            result.name = name
            result.layout = layout.domainValue
            return result
        }
    }
    struct ConnectionHistoryEntry: Codable, Identifiable {
        enum Kind: String, Codable { case ssh, telnet, sftp }
        var id: UUID = UUID()
        var hostID: Host.ID
        var kind: Kind
        var connectedAt: Date = Date()
        var sourceDeviceID: UUID?
        var endedAt: Date?
        init(_ value: TermindDomain.ConnectionHistoryEntry) {
            self.id = value.id
            self.hostID = value.hostID
            self.kind = Kind(rawValue: value.kind.rawValue)!
            self.connectedAt = value.connectedAt
            self.sourceDeviceID = value.sourceDeviceID
            self.endedAt = value.endedAt
        }
        var domainValue: TermindDomain.ConnectionHistoryEntry {
            var result = TermindDomain.ConnectionHistoryEntry(hostID: hostID, kind: .ssh)
            result.id = id
            result.hostID = hostID
            result.kind = TermindDomain.ConnectionHistoryEntry.Kind(rawValue: kind.rawValue)!
            result.connectedAt = connectedAt
            result.sourceDeviceID = sourceDeviceID
            result.endedAt = endedAt
            return result
        }
    }
    struct DeviceRecord: Codable, Identifiable {
        var id: UUID
        var displayName: String
        init(_ value: TermindDomain.DeviceRecord) {
            self.id = value.id
            self.displayName = value.displayName
        }
        var domainValue: TermindDomain.DeviceRecord {
            var result = TermindDomain.DeviceRecord(id: id, displayName: displayName)
            result.id = id
            result.displayName = displayName
            return result
        }
    }
    struct HostEnvironmentVariable: Codable {
        var variable: String
        var value: String
        init(_ value: TermindDomain.HostEnvironmentVariable) {
            self.variable = value.variable
            self.value = value.value
        }
        var domainValue: TermindDomain.HostEnvironmentVariable {
            var result = TermindDomain.HostEnvironmentVariable(variable: variable, value: value)
            result.variable = variable
            result.value = value
            return result
        }
    }
    struct HostProxy: Codable {
        enum ProtocolKind: String, Codable { case http, socks5 }
        var kind: ProtocolKind = .http
        var hostname: String = ""
        var port: Int = 8080
        var username: String = ""
        var identityID: Identity.ID?
        init(_ value: TermindDomain.HostProxy) {
            self.kind = ProtocolKind(rawValue: value.kind.rawValue)!
            self.hostname = value.hostname
            self.port = value.port
            self.username = value.username
            self.identityID = value.identityID
        }
        var domainValue: TermindDomain.HostProxy {
            var result = TermindDomain.HostProxy()
            result.kind = TermindDomain.HostProxy.ProtocolKind(rawValue: kind.rawValue)!
            result.hostname = hostname
            result.port = port
            result.username = username
            result.identityID = identityID
            return result
        }
    }
    struct DetectedDistribution: Codable, Identifiable {
        var id: String
        var likeIDs: [String]
        init?(id: String, likeIDs: [String] = []) {
            guard let id = RemoteSystemIdentifier.normalized(id) else { return nil }
            self.id = id
            self.likeIDs = RemoteSystemIdentifier.normalizedList(likeIDs)
                .filter { $0 != id }
        }
        private enum CodingKeys: String, CodingKey { case id, likeIDs }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let proposedID = try container.decode(String.self, forKey: .id)
            let proposedLikeIDs =
                try container.decodeIfPresent(
                    [String].self, forKey: .likeIDs
                ) ?? []
            guard let value = Self(id: proposedID, likeIDs: proposedLikeIDs) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .id, in: container,
                    debugDescription: "Invalid distribution identifier"
                )
            }
            self = value
        }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            if !likeIDs.isEmpty { try container.encode(likeIDs, forKey: .likeIDs) }
        }
        init(_ value: TermindDomain.DetectedDistribution) {
            self.id = value.id
            self.likeIDs = value.likeIDs
        }
        var domainValue: TermindDomain.DetectedDistribution {
            var result = TermindDomain.DetectedDistribution(id: id, likeIDs: likeIDs)!
            result.id = id
            result.likeIDs = likeIDs
            return result
        }
    }
    enum WorkspaceTemplatePane: Codable {
        case ssh(hostID: UUID)
        case telnet(hostID: UUID)
        case sftp(hostID: UUID)
        case empty
        init(_ value: TermindDomain.WorkspaceTemplatePane) throws {
            switch value {
            case .ssh(let id): self = .ssh(hostID: id)
            case .telnet(let id): self = .telnet(hostID: id)
            case .sftp(let id): self = .sftp(hostID: id)
            case .empty: self = .empty
            case .mosh, .eternalTerminal: throw CocoaError(.coderInvalidValue)
            }
        }
        var domainValue: TermindDomain.WorkspaceTemplatePane {
            switch self {
            case .ssh(let id): .ssh(hostID: id)
            case .telnet(let id): .telnet(hostID: id)
            case .sftp(let id): .sftp(hostID: id)
            case .empty: .empty
            }
        }
    }
    enum WorkspaceTemplateSplitAxis: String, Codable { case horizontal, vertical }
    indirect enum WorkspaceTemplateLayout: Codable {
        case pane(WorkspaceTemplatePane)
        case split(
            axis: WorkspaceTemplateSplitAxis, fraction: Double,
            first: WorkspaceTemplateLayout, second: WorkspaceTemplateLayout)
        init(_ value: TermindDomain.WorkspaceTemplateLayout) throws {
            switch value {
            case .pane(let pane): self = .pane(try WorkspaceTemplatePane(pane))
            case .split(let axis, let fraction, let first, let second):
                self = .split(
                    axis: WorkspaceTemplateSplitAxis(rawValue: axis.rawValue)!, fraction: fraction,
                    first: try Self(first), second: try Self(second))
            }
        }
        var domainValue: TermindDomain.WorkspaceTemplateLayout {
            switch self {
            case .pane(let pane): .pane(pane.domainValue)
            case .split(let axis, let fraction, let first, let second):
                .split(
                    axis: TermindDomain.WorkspaceTemplateSplitAxis(rawValue: axis.rawValue)!, fraction: fraction,
                    first: first.domainValue, second: second.domainValue)
            }
        }
    }
    enum Payload: Codable {
        case host(Host)
        case hostGroup(HostGroup)
        case identity(Identity)
        case sshKey(SSHKeyRef)
        case knownHost(KnownHostEntry)
        case snippet(Snippet)
        case snippetPackage(SnippetPackage)
        case portForwarding(PortForwardingRule)
        case workspaceTemplate(WorkspaceTemplate)
        case connectionHistory(ConnectionHistoryEntry)
        case device(DeviceRecord)
        init(_ value: VaultRecordPayload) throws {
            switch value {
            case .host(let value): self = .host(Host(value))
            case .hostGroup(let value): self = .hostGroup(HostGroup(value))
            case .identity(let value): self = .identity(Identity(value))
            case .sshKey(let value): self = .sshKey(SSHKeyRef(value))
            case .knownHost(let value): self = .knownHost(KnownHostEntry(value))
            case .snippet(let value): self = .snippet(Snippet(value))
            case .snippetPackage(let value): self = .snippetPackage(SnippetPackage(value))
            case .portForwarding(let value): self = .portForwarding(PortForwardingRule(value))
            case .workspaceTemplate(let value): self = .workspaceTemplate(try WorkspaceTemplate(value))
            case .connectionHistory(let value):
                guard ConnectionHistoryEntry.Kind(rawValue: value.kind.rawValue) != nil else {
                    throw CocoaError(.coderInvalidValue)
                }
                self = .connectionHistory(ConnectionHistoryEntry(value))
            case .device(let value): self = .device(DeviceRecord(value))
            }
        }
        var domainValue: VaultRecordPayload {
            switch self {
            case .host(let value): .host(value.domainValue)
            case .hostGroup(let value): .hostGroup(value.domainValue)
            case .identity(let value): .identity(value.domainValue)
            case .sshKey(let value): .sshKey(value.domainValue)
            case .knownHost(let value): .knownHost(value.domainValue)
            case .snippet(let value): .snippet(value.domainValue)
            case .snippetPackage(let value): .snippetPackage(value.domainValue)
            case .portForwarding(let value): .portForwarding(value.domainValue)
            case .workspaceTemplate(let value): .workspaceTemplate(value.domainValue)
            case .connectionHistory(let value): .connectionHistory(value.domainValue)
            case .device(let value): .device(value.domainValue)
            }
        }
    }
    struct Envelope: Codable {
        var formatVersion: Int
        var key: VaultRecordKey
        var version: VaultVersion
        var isDeleted: Bool
        var payload: Payload?
        init(_ value: VaultEnvelope) throws {
            try VaultWireV1.validateRepresentable(value.payload)
            formatVersion = value.formatVersion
            key = value.key
            version = value.version
            isDeleted = value.isDeleted
            payload = try value.payload.map(Payload.init)
        }
        var domainValue: VaultEnvelope {
            VaultEnvelope(
                key: key, version: version, isDeleted: isDeleted,
                payload: payload?.domainValue, formatVersion: formatVersion)
        }
    }
}
