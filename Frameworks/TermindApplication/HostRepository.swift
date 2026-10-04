import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated enum HostUseCase: Hashable, Sendable {
    case preferredTerminal
    case sshTerminal
    case telnetTerminal
    case sftp
    case jumpHost
    case metrics
    case portForwarding
    case snippetExecution
    case keyExport

    public var protocolRequirement: HostProtocolRequirement {
        switch self {
        case .preferredTerminal: .anyTerminal
        case .telnetTerminal: .telnet
        case .sshTerminal, .sftp, .jumpHost, .metrics, .portForwarding, .snippetExecution, .keyExport: .ssh
        }
    }
}

public nonisolated struct HostProtocolUnavailableError: LocalizedError, Equatable, Sendable {
    public var useCase: HostUseCase

    public init(useCase: HostUseCase) { self.useCase = useCase }

    public var errorDescription: String? {
        switch useCase.protocolRequirement {
        case .anyTerminal: String(localized: "No terminal protocol is enabled for this Host.")
        case .ssh: String(localized: "SSH is disabled for this Host.")
        case .telnet: String(localized: "Telnet is disabled for this Host.")
        }
    }
}

public nonisolated struct HostLibrarySnapshot: Equatable, Sendable {
    public var hosts: [Host]
    public var groups: [HostGroup]

    public static let empty = HostLibrarySnapshot(hosts: [], groups: [])
    public init(hosts: [Host], groups: [HostGroup]) {
        self.hosts = hosts
        self.groups = groups
    }

}

@MainActor
public protocol HostRepository: AnyObject {
    func snapshot() throws -> RepositoryChange<HostLibrarySnapshot>
    func changes() -> AsyncStream<RepositoryChange<HostLibrarySnapshot>>
    func refresh() throws
    func upsertHost(_ host: Host) throws
    func requestHostDeletion(_ hostID: Host.ID) throws
    func clearReferencesForDeletedHost(_ hostID: Host.ID) throws
    func finalizeHostDeletion(_ hostID: Host.ID) throws
}
