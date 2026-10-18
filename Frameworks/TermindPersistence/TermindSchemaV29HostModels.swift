import Foundation
import SwiftData
import TermindDomain

import struct TermindDomain.Host

/// The Host model shipped in V30. Its historical namespace is retained to preserve SwiftData model identity.
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
    }
}

/// V32 removes the obsolete Host usage column. ConnectionHistoryEntry is the
/// sole owner of connection recency and duration.
public enum TermindSchemaV32HostModels {
    @Model
    public final class PersistentHost {
        @Attribute(.unique) public var id: UUID = UUID()
        public var name = ""
        public var address = ""
        public var sshEnabled = true
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
        public var startupSnippetID: UUID?
        public var environmentVariableNames: [String] = []
        public var environmentVariableValues: [String] = []
        public var portForwardingMaxConnections: Int? = Host.defaultPortForwardingMaxConnections
        public var detectedDistributionID: String?
        public var detectedDistributionLikeIDs: [String] = []
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
    }
}
