import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@Suite @MainActor
struct SSHHostKeyAuthorizationTests {
    @Test func synchronousPromptResolutionCompletesExactlyOnce() async {
        let coordinator = SSHHostKeyAuthorizationCoordinator()
        let observation = SSHHostKeyObservation(
            hostname: "server.example", port: 22,
            algorithm: .ed25519, fingerprint: "SHA256:new")
        let decision = await coordinator.authorize(
            SSHHostKeyChallenge(hostID: UUID(), observation: observation, expectedHostKeys: [])
        ) { _ in
            #expect(coordinator.continueOnce(observation))
        }

        #expect(decision == .accept)
        #expect(coordinator.pending == nil)
        coordinator.reject()
        #expect(coordinator.pending == nil)
    }

    @Test func authenticationPromptResolverSharesHostAndProxyProjection() throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        var host = Host(name: "Server", host: "server.example", identityID: identity.id)
        host.proxy = HostProxy(
            hostname: "proxy.example", port: 8080,
            username: "proxy-user", identityID: identity.id)
        let store = HostLibraryModel(hosts: [host], identities: [identity])

        let direct = SSHAuthenticationPromptResolver.host(
            host, using: store, failureMessage: "failed",
            mode: .serverChallenge, allowsSaving: false)
        #expect(direct.selectedIdentityID == identity.id)
        #expect(direct.username == identity.username)
        #expect(direct.mode == .serverChallenge)
        #expect(!direct.allowsSaving)

        let proxy = try #require(
            SSHAuthenticationPromptResolver.proxy(
                for: host, using: store,
                submission: SSHProxyAuthenticationSubmission(username: "retry", identityID: identity.id),
                allowsSaving: false))
        #expect(proxy.isProxy)
        #expect(proxy.username == "retry")
        #expect(proxy.selectedIdentityID == identity.id)
        #expect(!proxy.allowsSaving)
    }

    @Test func pinnedHostKeyAcceptsOnlyTheTrustedIdentity() throws {
        let observed = constrainedObservation()
        try SSHConnectionOpener.validateHostKey(observed, expected: [observed.identity])
        #expect(throws: TermindSSHError.self) {
            try SSHConnectionOpener.validateHostKey(observed, expected: [])
        }
        #expect(throws: TermindSSHError.self) {
            try SSHConnectionOpener.validateHostKey(
                observed,
                expected: [SSHHostKeyIdentity(algorithm: .ed25519, fingerprint: "SHA256:other")])
        }
    }

    @Test func knownKeyWithMatchingConstraintBypassesInteraction() async throws {
        let hostID = UUID()
        let observation = constrainedObservation()
        let recorder = HostKeyAuthorizerRecorder()

        try await SSHConnectionOpener.authorizeHostKey(
            hostID: hostID, observed: observation,
            expected: [observation.identity], constraint: matchingConstraint(),
            authorizer: { challenge in
                await recorder.record(challenge)
                return .accept
            })

        #expect(await recorder.challenges.isEmpty)
    }

    @Test func mismatchedConstraintRejectsWithoutInteraction() async {
        let observation = constrainedObservation()
        let recorder = HostKeyAuthorizerRecorder()
        let mismatch = SSHHostKeyConstraint(algorithm: .rsa, legacyMD5: Data(repeating: 0xff, count: 16))

        await #expect(throws: TermindSSHError.self) {
            try await SSHConnectionOpener.authorizeHostKey(
                hostID: UUID(), observed: observation, expected: [], constraint: mismatch,
                authorizer: { challenge in
                    await recorder.record(challenge)
                    return .accept
                })
        }
        #expect(await recorder.challenges.isEmpty)
    }

    @Test func matchingConstraintMarksFirstUsePromptButCannotOverrideKnownHosts() async throws {
        let observation = constrainedObservation()
        let recorder = HostKeyAuthorizerRecorder()
        try await SSHConnectionOpener.authorizeHostKey(
            hostID: UUID(), observed: observation, expected: [], constraint: matchingConstraint(),
            authorizer: { challenge in
                await recorder.record(challenge)
                return .accept
            })
        let challenge = try #require(await recorder.challenges.first)
        #expect(challenge.provisionalConstraintMatched)
        #expect(SSHHostKeyPrompt(challenge: challenge).uriFingerprintMatched)

        await #expect(throws: TermindSSHError.self) {
            try await SSHConnectionOpener.authorizeHostKey(
                hostID: UUID(), observed: observation,
                expected: [SSHHostKeyIdentity(algorithm: .ed25519, fingerprint: "SHA256:old")],
                constraint: matchingConstraint(), authorizer: { _ in .accept })
        }
    }

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
            await controller.authorizeHostKey(challenge)
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
            await controller.authorizeHostKey(challenge)
        }
        await waitForPrompt(controller)
        controller.trustHostKey(observation, using: store)

        #expect(await decision.value == .accept)
        #expect(store.knownHosts(for: host).map(\.identity) == [observation.identity])
    }

    @Test func disconnectRejectsAndClearsAPendingDecision() async throws {
        let host = Host(name: "Server", host: "server.example")
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
                )
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

    private func constrainedObservation() -> SSHHostKeyObservation {
        SSHHostKeyObservation(
            hostname: "server.example", port: 22, algorithm: .rsa,
            fingerprint: "SHA256:new", legacyMD5Fingerprint: Data(0..<16))
    }

    private func matchingConstraint() -> SSHHostKeyConstraint {
        SSHHostKeyConstraint(algorithm: .rsa, legacyMD5: Data(0..<16))
    }
}

private actor HostKeyAuthorizerRecorder {
    private(set) var challenges: [SSHHostKeyChallenge] = []
    func record(_ challenge: SSHHostKeyChallenge) { challenges.append(challenge) }
}
