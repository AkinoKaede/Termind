import Foundation
import SwiftData
import TermindDomain

import struct TermindDomain.Host

/// V29 adds independent SSH and Telnet profiles while preserving the Host entity and V28 SSH columns.
public enum TermindSchemaV29HostModels {
    @Model
    public final class PersistentHost {
        @Attribute(.unique) public var id: UUID = UUID()
        public var name = ""
        public var address = ""
        public var sshEnabled = true
        /// Retains V28's property name so its stored value migrates as the SSH port.
        public var port = 22
        /// Retains V28's property name so its stored value migrates as the SSH Identity.
        public var identityID: UUID?
        /// Retains V28's property name so its stored value migrates as the SSH Charset.
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
        public var startupSnippetID: UUID?
        public var environmentVariableNames: [String] = []
        public var environmentVariableValues: [String] = []
        public var portForwardingMaxConnections: Int? = Host.defaultPortForwardingMaxConnections
        public var detectedDistributionID: String?
        public var detectedDistributionLikeIDs: [String] = []
        public var lastUsedAt: Date?
        public var sortIndex = 0.0

        public init(_ value: Host) {
            id = value.id
            apply(value)
        }

        public func apply(_ value: Host) {
            name = value.name
            address = value.host
            sshEnabled = value.sshEnabled
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
            shellIntegrationMode = value.shellIntegrationMode.rawValue
            startupSnippetID = value.startupSnippetID
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
                charset: RemoteCharset(rawValue: charset) ?? .utf8,
                sshEnabled: sshEnabled, telnetEnabled: telnetEnabled, telnetPort: telnetPort,
                telnetIdentityID: telnetIdentityID,
                telnetCharset: RemoteCharset(rawValue: telnetCharset) ?? .utf8,
                groupID: groupID, tags: tags,
                colorTag: TagColor(rawValue: colorTag) ?? .none,
                detectedDistribution: detectedDistributionID.flatMap {
                    DetectedDistribution(id: $0, likeIDs: detectedDistributionLikeIDs)
                },
                sortIndex: sortIndex,
                shellIntegrationMode: HostShellIntegrationMode(rawValue: shellIntegrationMode)
                    ?? .followGlobalSettings,
                startupSnippetID: startupSnippetID,
                environmentVariables: zip(environmentVariableNames, environmentVariableValues).map {
                    HostEnvironmentVariable(variable: $0, value: $1)
                },
                portForwardingMaxConnections: portForwardingMaxConnections
                    ?? Host.defaultPortForwardingMaxConnections
            )
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
