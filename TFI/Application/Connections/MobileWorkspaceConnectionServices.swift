import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure

import struct TermindDomain.Host

@MainActor
struct MobileWorkspaceConnectionServices {
    var discoverHostKey:
        (Host.ID, String, Int, SSHTransportProxy?, [SSHRouteHopConfiguration]) async throws -> SSHHostKeyObservation
    var makeSSHSession:
        (
            @escaping SSHSessionActor.OutputHandler, @escaping SSHSessionActor.ExitHandler,
            @escaping SSHSessionActor.ShellIntegrationHandler
        ) -> SSHSessionActor
    var connectSSH:
        (
            SSHSessionActor, SSHConnectionConfiguration, Bool, UInt16, UInt16,
            SSHRouteProgressHandler?
        ) async throws -> Void
    var connectSFTP:
        (
            SSHConnectionConfiguration, SSHRouteProgressHandler?,
            (@Sendable (String) -> Void)?
        ) async throws -> any SFTPClientProtocol
    var writeSSH: (SSHSessionActor, Data) async -> Void
}
