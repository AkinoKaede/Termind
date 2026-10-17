import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure

import struct TermindDomain.Host

@MainActor
struct MobileWorkspaceConnectionServices {
    var makePTYChannel:
        (
            @escaping SSHPTYChannel.OutputHandler, @escaping SSHPTYChannel.ExitHandler,
            @escaping SSHPTYChannel.ShellIntegrationHandler
        ) -> SSHPTYChannel
    var connectSSH:
        (
            SSHPTYChannel, SSHConnectionRequest, Bool, UInt16, UInt16,
            SSHRouteProgressHandler?
        ) async throws -> Void
    var connectSFTP:
        (
            SSHConnectionRequest, SSHRouteProgressHandler?,
            (@Sendable (String) -> Void)?
        ) async throws -> any SFTPClientProtocol
    var writeSSH: (SSHPTYChannel, Data) async -> Void
    var submitInitialCommand: @MainActor (SSHPTYChannel, Data, SSHOrdinaryStartupTicket) async -> Void = {
        await $0.submitInitialCommand($1, ticket: $2)
    }

}
