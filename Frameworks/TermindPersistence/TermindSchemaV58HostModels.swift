import Foundation
import SwiftData
import TermindDomain

import struct TermindDomain.Host

public enum TermindSchemaV58HostModels {
    @Model
    public final class PersistentHost {
        @Attribute(.unique) public var id: UUID = UUID()
        public var createdAt: Date?
        public var name = ""
        public var address = ""
        public var sshEnabled = true
        public var wakeMACAddress = ""
        public var automaticallyWake = false
        public var terminalTransportsData: Data?
        public var port = 22
        public var identityID: UUID?
        public var charset = RemoteCharset.utf8.rawValue
        public var telnetEnabled = false
        public var telnetPort = 23
        public var telnetIdentityID: UUID?
        public var telnetCharset = RemoteCharset.utf8.rawValue
        public var telnetProxyProtocol: String?
        public var telnetProxyHostname = ""
        public var telnetProxyPort = 0
        public var telnetProxyUsername = ""
        public var telnetProxyIdentityID: UUID?
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
        public var shellIntegrationMode = HostShellIntegrationMode.followGlobalSettings.rawValue
        public var sessionPersistenceEnabled = false
        public var sessionPersistenceBackend = "tmux"
        public var sessionPersistenceOnConnect = "ask"
        public var agentForwardingEnabled = false
        public var startupSnippetID: UUID?
        public var environmentVariableNames: [String] = []
        public var environmentVariableValues: [String] = []
        public var portForwardingMaxConnections: Int? = Host.defaultPortForwardingMaxConnections
        public var iconOverrideID: String?
        public var detectedDistributionID: String?
        public var detectedDistributionLikeIDs: [String] = []
        public var sortIndex = 0.0

        public init(_ value: Host) {
            id = value.id
            apply(value)
        }

        public func apply(_ value: Host) {
            createdAt = value.createdAt
            wakeMACAddress = value.wakeOnLAN.macAddress
            automaticallyWake = value.wakeOnLAN.automaticallyWake
            name = value.name
            address = value.host
            sshEnabled = value.sshEnabled
            terminalTransportsData = try? JSONEncoder().encode(value.terminalTransports)
            port = value.sshPort
            identityID = value.sshIdentityID
            charset = value.sshCharset.rawValue
            telnetEnabled = value.telnetEnabled
            telnetPort = value.telnetPort
            telnetIdentityID = value.telnetIdentityID
            telnetCharset = value.telnetCharset.rawValue
            telnetProxyProtocol = value.telnetProxy?.kind.rawValue
            telnetProxyHostname = value.telnetProxy?.hostname ?? ""
            telnetProxyPort = value.telnetProxy?.port ?? 0
            telnetProxyUsername = value.telnetProxy?.username ?? ""
            telnetProxyIdentityID = value.telnetProxy?.identityID
            jumpHostID = value.jumpHostID
            proxyProtocol = value.proxy?.kind.rawValue
            proxyHostname = value.proxy?.hostname ?? ""
            proxyPort = value.proxy?.port ?? 0
            proxyUsername = value.proxy?.username ?? ""
            proxyIdentityID = value.proxy?.identityID
            sftpSessionInitialPath = value.sftpChannelInitialPath
            groupID = value.groupID
            tags = value.tags
            colorTag = value.colorTag.rawValue
            iconOverrideID = value.iconOverrideID
            shellIntegrationMode = value.shellIntegrationMode.rawValue
            startupSnippetID = value.startupSnippetID
            agentForwardingEnabled = value.agentForwardingEnabled
            sessionPersistenceEnabled = value.sessionPersistence.enabled
            sessionPersistenceBackend = value.sessionPersistence.backend.rawValue
            sessionPersistenceOnConnect = value.sessionPersistence.onConnect.rawValue
            environmentVariableNames = value.environmentVariables.map(\.variable)
            environmentVariableValues = value.environmentVariables.map(\.value)
            portForwardingMaxConnections = Host.normalizedPortForwardingMaxConnections(
                value.portForwardingMaxConnections)
            detectedDistributionID = value.detectedDistribution?.id
            detectedDistributionLikeIDs = value.detectedDistribution?.likeIDs ?? []
            sortIndex = value.sortIndex
        }

        public var value: Host {
            var host = Host(
                id: id, name: name, host: address, port: port, identityID: identityID,
                createdAt: createdAt,
                charset: RemoteCharset(rawValue: charset) ?? .utf8,
                sshEnabled: sshEnabled, telnetEnabled: telnetEnabled, telnetPort: telnetPort,
                telnetIdentityID: telnetIdentityID,
                telnetCharset: RemoteCharset(rawValue: telnetCharset) ?? .utf8,
                groupID: groupID, tags: tags,
                colorTag: TagColor(rawValue: colorTag) ?? .none,
                detectedDistribution: detectedDistributionID.flatMap {
                    DetectedDistribution(id: $0, likeIDs: detectedDistributionLikeIDs)
                },
                iconOverrideID: iconOverrideID, sortIndex: sortIndex,
                shellIntegrationMode: HostShellIntegrationMode(rawValue: shellIntegrationMode)
                    ?? .followGlobalSettings,
                startupSnippetID: startupSnippetID, agentForwardingEnabled: agentForwardingEnabled,
                sessionPersistence: SessionPersistencePreferences(
                    enabled: sessionPersistenceEnabled, backend: .init(rawValue: sessionPersistenceBackend),
                    onConnect: .init(rawValue: sessionPersistenceOnConnect) ?? .ask),
                environmentVariables: zip(environmentVariableNames, environmentVariableValues).map {
                    HostEnvironmentVariable(variable: $0, value: $1)
                },
                portForwardingMaxConnections: portForwardingMaxConnections
                    ?? Host.defaultPortForwardingMaxConnections
            )
            host.wakeOnLAN = .init(macAddress: wakeMACAddress, automaticallyWake: automaticallyWake)
            host.terminalTransports =
                terminalTransportsData.flatMap {
                    try? JSONDecoder().decode(HostTerminalTransports.self, from: $0)
                } ?? .init()
            host.jumpHostID = jumpHostID
            host.sftpChannelInitialPath = sftpSessionInitialPath
            if let telnetProxyProtocol, let kind = HostProxy.ProtocolKind(rawValue: telnetProxyProtocol) {
                host.telnetProxy = HostProxy(
                    kind: kind, hostname: telnetProxyHostname, port: telnetProxyPort,
                    username: telnetProxyUsername, identityID: telnetProxyIdentityID)
            }
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
