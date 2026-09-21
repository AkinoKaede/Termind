import Foundation
import SwiftData
import TermindDomain

import struct TermindDomain.Host

/// V28 adds the remote text charset while preserving the Host entity name.
public enum TermindSchemaV28HostModels {
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
        public var charset = RemoteCharset.utf8.rawValue
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
            port = value.port
            identityID = value.identityID
            jumpHostID = value.jumpHostID
            proxyProtocol = value.proxy?.kind.rawValue
            proxyHostname = value.proxy?.hostname ?? ""
            proxyPort = value.proxy?.port ?? 0
            proxyUsername = value.proxy?.username ?? ""
            proxyIdentityID = value.proxy?.identityID
            sftpSessionInitialPath = value.sftpChannelInitialPath
            charset = value.charset.rawValue
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
                id: id, name: name, host: address, port: port,
                identityID: identityID, charset: RemoteCharset(rawValue: charset) ?? .utf8,
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
