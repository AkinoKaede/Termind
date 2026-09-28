import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@MainActor
struct SecurityKeySigningCoordinatorTests {
    @Test func silentRequestsNeverPublishAUserPromptAndUVDefaultsToPreferred() async throws {
        let credential = SecurityKeyCredential(credentialID: Data([1]), publicKeyX963: Data())
        #expect(credential.userVerification == .preferred)
        let request = SecurityKeySigningRequest(
            hostID: UUID(), hostname: "fixture.invalid",
            credential: credential, challenge: Data([1]), allowsUserInteraction: false)
        let coordinator = SecurityKeySigningCoordinator()
        await #expect(throws: SSHInteractionRequired.self) { try await coordinator.sign(request) }
        #expect(coordinator.pending == nil)
    }

    @Test func cancellationClearsPendingAndLateResponseCannotCompleteNextRequest() async throws {
        let coordinator = SecurityKeySigningCoordinator()
        let request = SecurityKeySigningRequest(
            hostID: UUID(), hostname: "fixture.invalid",
            credential: .init(credentialID: Data([1]), publicKeyX963: Data()), challenge: Data([1]))
        let first = Task { try await coordinator.sign(request) }
        while coordinator.pending == nil { await Task.yield() }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(coordinator.pending == nil)
        let next = SecurityKeySigningRequest(
            hostID: UUID(), hostname: "fixture.invalid",
            credential: request.credential, challenge: Data([2]))
        let second = Task { try await coordinator.sign(next) }
        while coordinator.pending == nil { await Task.yield() }
        coordinator.respond(request.id, result: .failure(CancellationError()))
        #expect(coordinator.pending?.id == next.id)
        coordinator.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(coordinator.pending == nil)
    }
}

@MainActor
struct SecurityKeySigningSessionTests {
    @Test func automaticContinueStartsOnceAndOnlyRespondsOnce() async throws {
        var signs = 0
        var responses = 0
        let session = SecurityKeySigningSession(
            sign: {
                signs += 1
                return SecurityKeyAssertion(
                    credentialID: Data(), authenticatorData: Data(), clientDataJSON: Data(), signature: Data())
            }, respond: { _ in responses += 1 })
        session.startAutomatically()
        session.startAutomatically()
        #expect(session.isRunning)
        session.start()
        session.start()
        while !session.isFinished { await Task.yield() }
        session.cancel()
        #expect(signs == 1 && responses == 1)
    }

    @Test func autoStartsAndLateSuccessAfterCancelIsIgnored() async throws {
        var continuation: CheckedContinuation<SecurityKeyAssertion, Never>?
        var cancelled = 0
        var succeeded = 0
        let session = SecurityKeySigningSession(
            sign: {
                await withCheckedContinuation { continuation = $0 }
            },
            respond: { result in
                switch result {
                case .success: succeeded += 1
                case .failure(let error): if error is CancellationError { cancelled += 1 }
                }
            })
        session.startAutomatically()
        while continuation == nil { await Task.yield() }
        session.cancel()
        continuation?.resume(
            returning: SecurityKeyAssertion(
                credentialID: Data(), authenticatorData: Data(), clientDataJSON: Data(), signature: Data()))
        await Task.yield()
        #expect(cancelled == 1 && succeeded == 0)
        #expect(session.isFinished && !session.isRunning)
    }

    @Test func systemCancellationDoesNotCompleteJourneyCheckpoint() async throws {
        let connection = RemoteSessionConnectionController()
        let host = Host(name: "Fixture", host: "fixture.invalid")
        connection.journey.begin(host: host, route: [host], purpose: .sshSession, username: "root")
        let request = SecurityKeySigningRequest(
            hostID: host.id, hostname: host.host,
            credential: .init(credentialID: Data([1]), publicKeyX963: Data()), challenge: Data([1]), keyName: "YubiKey")
        let task = Task { try await connection.signWithSecurityKey(request) }
        while connection.securityKeySigning.pending == nil { await Task.yield() }
        connection.securityKeySigning.respond(request.id, result: .failure(CancellationError()))
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(connection.journey.completedCheckpoints.isEmpty)
        #expect(
            connection.journey.phase
                == .failed(String(localized: "Authentication was cancelled. Retry to continue connecting.")))
        #expect(!connection.hasConnectedOnce)
    }
}
