import Foundation
import SwiftData
import TermindDomain

import struct TermindDomain.Host

public enum TermindSchemaV22HostModels {
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
        public var shellIntegrationMode = HostShellIntegrationMode.followGlobalSettings.rawValue
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
            shellIntegrationMode = value.shellIntegrationMode.rawValue
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
                sortIndex: sortIndex,
                shellIntegrationMode: HostShellIntegrationMode(rawValue: shellIntegrationMode) ?? .followGlobalSettings
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
