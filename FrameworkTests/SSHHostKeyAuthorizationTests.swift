import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct SSHHostKeyAuthorizationTests {
    @Test func temporaryTrustResumesThePendingConnectionAttempt() async throws {
        let host = Host(name: "Server", host: "server.example")
        let store = HostLibraryModel(hosts: [host])
        let controller = RemoteSessionConnectionController()
        controller.journey.begin(
            host: host, route: [host], purpose: .sshSession,
            username: "deploy"
        )
        let observation = SSHHostKeyObservation(
            hostname: host.host, port: host.port,
            algorithm: .ed25519, fingerprint: "SHA256:new"
        )
        let challenge = SSHHostKeyChallenge(
            hostID: host.id, observation: observation,
            expectedHostKeys: []
        )

        let decision = Task {
            await controller.authorizeHostKey(challenge, using: store)
        }
        await waitForPrompt(controller)

        #expect(controller.useTemporaryHostKey(observation))
        #expect(await decision.value == .accept)
        #expect(controller.pendingHostKey == nil)
        #expect(controller.temporaryHostKeys[host.id] == observation.identity)
        #expect(store.knownHosts(for: host).isEmpty)
    }

    @Test func persistentTrustIsSavedBeforeTheAttemptResumes() async throws {
        let host = Host(name: "Server", host: "server.example")
        let store = HostLibraryModel(hosts: [host])
        let controller = RemoteSessionConnectionController()
        controller.journey.begin(
            host: host, route: [host], purpose: .sftpChannel,
            username: "deploy"
        )
        let observation = SSHHostKeyObservation(
            hostname: host.host, port: host.port,
            algorithm: .ed25519, fingerprint: "SHA256:new"
        )
        let challenge = SSHHostKeyChallenge(
            hostID: host.id, observation: observation,
            expectedHostKeys: []
        )

        let decision = Task {
            await controller.authorizeHostKey(challenge, using: store)
        }
        await waitForPrompt(controller)
        controller.trustHostKey(observation, using: store)

        #expect(await decision.value == .accept)
        #expect(store.knownHosts(for: host).map(\.identity) == [observation.identity])
    }

    @Test func disconnectRejectsAndClearsAPendingDecision() async throws {
        let host = Host(name: "Server", host: "server.example")
        let store = HostLibraryModel(hosts: [host])
        let controller = RemoteSessionConnectionController()
        controller.journey.begin(
            host: host, route: [host], purpose: .sshSession,
            username: "deploy"
        )
        let observation = SSHHostKeyObservation(
            hostname: host.host, port: host.port,
            algorithm: .ed25519, fingerprint: "SHA256:new"
        )

        let decision = Task {
            await controller.authorizeHostKey(
                SSHHostKeyChallenge(
                    hostID: host.id, observation: observation,
                    expectedHostKeys: []
                ),
                using: store
            )
        }
        await waitForPrompt(controller)
        controller.disconnect()

        #expect(await decision.value == .reject)
        #expect(controller.pendingHostKey == nil)
        #expect(controller.temporaryHostKeys.isEmpty)
    }

    private func waitForPrompt(
        _ controller: RemoteSessionConnectionController
    ) async {
        for _ in 0..<100 where controller.pendingHostKey == nil {
            await Task.yield()
        }
        #expect(controller.pendingHostKey != nil)
    }
}
