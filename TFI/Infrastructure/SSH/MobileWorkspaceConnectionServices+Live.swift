import Foundation
import TermindRemoteInfrastructure

extension MobileWorkspaceConnectionServices {
    static var live: MobileWorkspaceConnectionServices {
        live(coordinator: RemoteConnectionCoordinator())
    }

    static func live(coordinator: RemoteConnectionCoordinator) -> MobileWorkspaceConnectionServices {
        return MobileWorkspaceConnectionServices(
            makeSSHSession: { output, exit, shellIntegration in
                coordinator.makeSSHSession(output: output, exit: exit, shellIntegration: shellIntegration)
            },
            connectSSH: { session, request, shellIntegrationEnabled, columns, rows, progress in
                try await session.connect(
                    using: request,
                    shellIntegrationEnabled: shellIntegrationEnabled,
                    columns: columns,
                    rows: rows,
                    progress: progress
                )
            },
            connectSFTP: { request, progress, connectionFailure in
                try await coordinator.connectSFTP(
                    using: request, progress: progress, connectionFailure: connectionFailure)
            },
            writeSSH: { session, data in await session.write(data) })
    }
}
