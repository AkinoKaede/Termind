import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure

import struct TermindDomain.Host

@MainActor
struct MobileWorkspaceConnectionServices {
    var makeSSHSession:
        (
            @escaping SSHSessionActor.OutputHandler, @escaping SSHSessionActor.ExitHandler,
            @escaping SSHSessionActor.ShellIntegrationHandler
        ) -> SSHSessionActor
    var connectSSH:
        (
            SSHSessionActor, SSHConnectionRequest, Bool, UInt16, UInt16,
            SSHRouteProgressHandler?
        ) async throws -> Void
    var connectSFTP:
        (
            SSHConnectionRequest, SSHRouteProgressHandler?,
            (@Sendable (String) -> Void)?
        ) async throws -> any SFTPClientProtocol
    var writeSSH: (SSHSessionActor, Data) async -> Void

}
