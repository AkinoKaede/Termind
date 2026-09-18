import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct SSHInteractionPolicyTests {
    @Test func forbiddenPolicyCannotInvokeExplicitOrFallbackForms() async throws {
        let queue = SSHKeyboardInteractiveQueue()
        let configuration = SSHConnectionConfiguration(
            hostID: UUID(), host: "example.invalid", port: 22, username: "user", credentials: [], expectedHostKeys: [])
        let request = SSHConnectionRequest(
            configuration: configuration,
            authorizeHostKey: { _ in
                Issue.record("Host key form must not open")
                return .accept
            },
            keyboardInteractive: queue.handler, interactionPolicy: .forbidden
        ).withKeyboardInteractiveFallback(queue.handler).enforcingInteractionPolicy()
        let handler = try #require(request.keyboardInteractive)
        let challenge = SSHKeyboardInteractiveChallenge(
            connectionID: UUID(), hostID: configuration.hostID, hostname: configuration.host,
            port: 22, username: "user", round: 1, name: "OTP", instruction: "",
            prompts: [.init(text: "Code", echo: false)])
        await #expect(throws: SSHInteractionRequired.self) { try await handler(challenge) }
        #expect(queue.pending.isEmpty)
        let authorize = try #require(request.authorizeHostKey)
        await #expect(throws: SSHInteractionRequired.self) {
            try await authorize(
                SSHHostKeyChallenge(
                    hostID: configuration.hostID,
                    observation: SSHHostKeyObservation(
                        hostname: configuration.host, port: 22, algorithm: .ed25519, fingerprint: "new"),
                    expectedHostKeys: []))
        }
    }

    @Test func additionalConnectionRefreshesDurableTrustWithoutReusingOnceOnlyApproval() {
        let host = Host(name: "Server", host: "example.invalid")
        let jump = Host(name: "Jump", host: "jump.invalid")
        let trusted = KnownHostEntry(hostname: host.host, port: 22, algorithm: .ed25519, fingerprint: "saved")
        let store = HostLibraryModel(hosts: [host, jump], knownHosts: [trusted])
        let configuration = SSHConnectionConfiguration(
            hostID: host.id, host: host.host, port: 22, username: "temporary-user",
            credentials: [.password("temporary-password")], expectedHostKeys: [],
            jumps: [
                SSHRouteHopConfiguration(
                    id: jump.id, name: jump.name, host: jump.host, port: 22, username: "jump-user", credentials: [],
                    expectedHostKeys: [.init(algorithm: .ed25519, fingerprint: "once-only")])
            ])
        let additional = store.configurationForAdditionalConnection(from: configuration)
        #expect(additional.expectedHostKeys == [trusted.identity])
        #expect(additional.jumps[0].expectedHostKeys.isEmpty)
        #expect(additional.host == host.host)
        #expect(additional.username == "temporary-user")
        #expect(additional.jumps[0].username == "jump-user")
        if case .password(let value) = additional.credentials.first {
            #expect(value == "temporary-password")
        } else {
            Issue.record("The live credential snapshot must be retained")
        }
    }
}
