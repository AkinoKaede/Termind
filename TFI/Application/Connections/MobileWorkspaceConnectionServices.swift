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

    func withKeyboardInteractive(_ handler: @escaping SSHKeyboardInteractiveHandler) -> Self {
        var services = self
        services.connectSSH = { session, request, integration, columns, rows, progress in
            try await self.connectSSH(
                session, request.withKeyboardInteractiveFallback(handler), integration, columns, rows, progress
            )
        }
        services.connectSFTP = { request, progress, failure in
            try await self.connectSFTP(request.withKeyboardInteractiveFallback(handler), progress, failure)
        }
        return services
    }
}
