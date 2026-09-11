import Foundation
import TermindRemoteInfrastructure

extension MobileWorkspaceConnectionServices {
    static var live: MobileWorkspaceConnectionServices {
        let coordinator = RemoteConnectionCoordinator()
        return MobileWorkspaceConnectionServices(
            discoverHostKey: { hostID, host, port, proxy, jumps in
                try await SSHSessionActor.discoverHostKey(
                    hostID: hostID, host: host, port: port, proxy: proxy, jumps: jumps)
            },
            makeSSHSession: { output, exit, shellIntegration in
                coordinator.makeSSHSession(output: output, exit: exit, shellIntegration: shellIntegration)
            },
            connectSSH: { session, configuration, shellIntegrationEnabled, columns, rows, progress in
                try await session.connect(
                    hostID: configuration.hostID,
                    host: configuration.host,
                    port: configuration.port,
                    username: configuration.username,
                    credentials: configuration.credentials,
                    expectedHostKeys: configuration.expectedHostKeys,
                    proxy: configuration.proxy,
                    jumps: configuration.jumps,
                    shellIntegrationEnabled: shellIntegrationEnabled,
                    columns: columns,
                    rows: rows,
                    progress: progress
                )
            },
            connectSFTP: { configuration, progress, connectionFailure in
                try await coordinator.connectSFTP(
                    using: configuration, progress: progress, connectionFailure: connectionFailure)
            },
            writeSSH: { session, data in await session.write(data) })
    }
}
