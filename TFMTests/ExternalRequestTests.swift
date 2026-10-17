import AgentKit
import AppKit
import Foundation
import Observation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite(.serialized)
@MainActor
struct ExternalAuthCoordinatorTests {
    @Test(.requiresVisibleWindow) func interactiveResponsesAreScopedAndInformationalRoundsComplete() async throws {
        let coordinator = ExternalAuthCoordinator()
        let challenge = SSHKeyboardInteractiveChallenge(
            connectionID: UUID(), hostID: UUID(), hostname: "server.example", port: 22,
            username: "deploy", round: 1, name: "PAM", instruction: "OTP",
            prompts: [.init(text: "Code", echo: false)]
        )
        let task = Task { try await coordinator.keyboardInteractive(challenge) }
        for _ in 0..<1_000 where coordinator.current == nil { await Task.yield() }
        #expect(coordinator.current?.id == challenge.id)
        coordinator.respondSSH(.keyboardInteractive(["stale"]), requestID: UUID())
        #expect(coordinator.current?.id == challenge.id)
        coordinator.respondSSH(.keyboardInteractive(["123456"]), requestID: challenge.id)
        #expect(try await task.value == ["123456"])
        var notice = challenge
        notice.id = UUID()
        notice.prompts = []
        #expect(try await coordinator.keyboardInteractive(notice) == [])
        #expect(coordinator.current == nil)
    }

    @Test(.requiresVisibleWindow) func stoppingMCPPreservesAppAuthentication() async throws {
        let coordinator = ExternalAuthCoordinator()
        let challenge = SSHKeyboardInteractiveChallenge(
            connectionID: UUID(), hostID: UUID(), hostname: "server.example", port: 22,
            username: "deploy", round: 1, name: "PAM", instruction: "OTP",
            prompts: [.init(text: "Code", echo: false)]
        )
        let appTask = Task { try await coordinator.keyboardInteractive(challenge) }
        let externalTask = Task {
            await coordinator.enqueue(authenticationRequest(name: "MCP"), clientName: "Termind", runID: UUID())
        }
        try await waitUntil { coordinator.pending.count == 2 }
        coordinator.cancelExternalRequests()
        #expect(await externalTask.value == .cancelled)
        #expect(coordinator.pending.map(\.id) == [challenge.id])
        coordinator.respondSSH(.keyboardInteractive(["123456"]), requestID: challenge.id)
        #expect(try await appTask.value == ["123456"])
    }

    @Test
    func authenticationWindowUsesFocusableNativeChrome() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 240),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        ExternalAuthWindowChrome.configure(window)

        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.miniaturizable))
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .visible)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(window.canBecomeKey)
        #expect(!window.isOpaque)
        #expect(window.backgroundColor.alphaComponent == 0)
        #expect(!window.isMovableByWindowBackground)
        #expect(window.hasShadow)
        #expect(window.level == .floating)
        #expect(!window.hidesOnDeactivate)
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.zoomButton)?.isHidden == false)
    }

    @Test(.requiresVisibleWindow)
    func popupQueueResumesInFIFOOrder() async throws {
        let coordinator = ExternalAuthCoordinator()
        let runID = UUID()
        let firstRequest = authenticationRequest(name: "First")
        let secondRequest = authenticationRequest(name: "Second")
        let first = Task {
            await coordinator.enqueue(firstRequest, clientName: "Claude", runID: runID)
        }
        let second = Task {
            await coordinator.enqueue(secondRequest, clientName: "Codex", runID: runID)
        }
        try await waitUntil { coordinator.pending.count == 2 }

        #expect(coordinator.current?.request.id == firstRequest.id)
        #expect(coordinator.current?.clientName == "Claude")
        let answer = AgentSSHAuthenticationAnswer(
            username: "deploy", password: "secret", save: false
        )
        coordinator.respondSSH(.submit(answer))
        #expect(await first.value == .submit(answer))
        #expect(coordinator.current?.request.id == secondRequest.id)

        coordinator.respondSSH(.cancelled)
        #expect(await second.value == .cancelled)
        #expect(coordinator.pending.isEmpty)
    }

    @Test(.requiresVisibleWindow)
    func protectedKeyCanRaisePassphraseImmediatelyAfterIdentity() async throws {
        let coordinator = ExternalAuthCoordinator()
        let handler = coordinator.handler(clientName: "Codex", runID: UUID())
        let invocationID = UUID()
        let hostID = UUID()
        let keyID = UUID()
        let identity = AgentSSHAuthenticationRequest(
            invocationID: invocationID, hostID: hostID,
            displayName: "Server", address: "server.example",
            mode: .identity, username: "", failureMessage: nil
        )
        let flow = Task {
            let first = await handler.sshInteraction.authenticate(identity)
            guard case .submit = first else { return first }
            return await handler.sshInteraction.authenticate(
                AgentSSHAuthenticationRequest(
                    invocationID: invocationID, hostID: hostID,
                    displayName: "Server", address: "server.example",
                    mode: .passphrase(keyID: keyID), username: "deploy",
                    selectedKeyID: keyID, failureMessage: nil
                )
            )
        }
        try await waitUntil { coordinator.current?.id == identity.id }

        coordinator.respondSSH(
            .submit(
                AgentSSHAuthenticationAnswer(
                    username: "deploy", keyID: keyID, save: false
                )))

        try await waitUntil {
            guard case .ssh(let request)? = coordinator.current?.request,
                case .passphrase(let presentedKeyID) = request.mode
            else { return false }
            return presentedKeyID == keyID
        }
        guard case .ssh(let passphrase)? = coordinator.current?.request else {
            Issue.record("Expected a Passphrase request")
            return
        }
        #expect(passphrase.username == "deploy")
        #expect(passphrase.selectedKeyID == keyID)

        let answer = AgentSSHAuthenticationAnswer(
            username: "deploy", passphrase: "one-use", keyID: keyID, save: false
        )
        coordinator.respondSSH(.submit(answer))
        #expect(await flow.value == .submit(answer))
        #expect(coordinator.pending.isEmpty)
    }

    @Test(.requiresVisibleWindow)
    func closingThePopupCancelsEveryWaiter() async throws {
        let coordinator = ExternalAuthCoordinator()
        let task = Task {
            await coordinator.enqueue(
                authenticationRequest(name: "Host"), clientName: "Client", runID: UUID()
            )
        }
        try await waitUntil { coordinator.current != nil }

        coordinator.windowClosed()

        #expect(await task.value == .cancelled)
        #expect(coordinator.pending.isEmpty)
    }

    @Test(.requiresVisibleWindow)
    func staleWindowDisappearanceCannotCancelANewerPassphraseRequest() async throws {
        let coordinator = ExternalAuthCoordinator()
        let firstRequest = authenticationRequest(name: "First")
        let first = Task {
            await coordinator.enqueue(
                firstRequest, clientName: "Client", runID: UUID()
            )
        }
        try await waitUntil { coordinator.current?.id == firstRequest.id }
        coordinator.respondSSH(.cancelled)
        #expect(await first.value == .cancelled)

        let keyID = UUID()
        let passphraseRequest = AgentSSHAuthenticationRequest(
            invocationID: UUID(), hostID: UUID(),
            displayName: "Server", address: "server.example",
            mode: .passphrase(keyID: keyID), username: "deploy",
            selectedKeyID: keyID, failureMessage: nil
        )
        let passphrase = Task {
            await coordinator.enqueue(
                passphraseRequest, clientName: "Client", runID: UUID()
            )
        }
        try await waitUntil { coordinator.current?.id == passphraseRequest.id }

        // The old scene completes its close after the new one has opened.
        coordinator.windowClosed(presenting: firstRequest.id)

        #expect(coordinator.current?.id == passphraseRequest.id)
        let answer = AgentSSHAuthenticationAnswer(
            username: "deploy", passphrase: "one-use",
            keyID: keyID, save: false
        )
        coordinator.respondSSH(.submit(answer))
        #expect(await passphrase.value == .submit(answer))
        #expect(coordinator.pending.isEmpty)
    }

    @Test(.requiresVisibleWindow)
    func secretRequestsUseTheSamePopupQueueAndRejectOrdinaryQuestions() async throws {
        let coordinator = ExternalAuthCoordinator()
        let runID = UUID()
        let request = AgentUserInputRequest(
            questions: [AgentUserQuestion(id: "secret", prompt: "Password", kind: .secret)],
            purpose: "sudo"
        )
        let task = Task {
            await coordinator.enqueue(request, clientName: "Claude", runID: runID)
        }
        try await waitUntil {
            if case .secret? = coordinator.current?.request { return true }
            return false
        }

        let response = AgentUserInputResponse.answered([
            AgentUserInputAnswer(questionID: "secret", value: .secret(agentSecret("value")))
        ])
        coordinator.respondSecret(response)
        #expect(await task.value == response)

        let ordinary = AgentUserInputRequest(
            questions: [AgentUserQuestion(id: "text", prompt: "Name", kind: .text)]
        )
        #expect(
            await coordinator.enqueue(ordinary, clientName: "Claude", runID: runID)
                == .cancelled
        )
    }

    @Test(.requiresVisibleWindow)
    func cancellingAQueuedSessionDoesNotRepresentTheCurrentPopup() async throws {
        let coordinator = ExternalAuthCoordinator()
        let currentRunID = UUID()
        let queuedRunID = UUID()
        let current = Task {
            await coordinator.enqueue(
                authenticationRequest(name: "Current"), clientName: "Claude",
                runID: currentRunID
            )
        }
        let queued = Task {
            await coordinator.enqueue(
                authenticationRequest(name: "Queued"), clientName: "Codex",
                runID: queuedRunID
            )
        }
        try await waitUntil { coordinator.pending.count == 2 }
        let revision = coordinator.presentationRevision

        coordinator.cancel(runID: queuedRunID)

        #expect(await queued.value == .cancelled)
        #expect(coordinator.current?.clientName == "Claude")
        #expect(coordinator.presentationRevision == revision)
        coordinator.cancel(runID: currentRunID)
        #expect(await current.value == .cancelled)
    }

    @Test(.requiresVisibleWindow)
    func visibleSecretTimesOutAndLeavesNoPendingPopup() async throws {
        let coordinator = ExternalAuthCoordinator()
        let request = secretRequest(timeout: .milliseconds(40))
        let task = Task {
            await coordinator.enqueue(request, clientName: "Claude", runID: UUID())
        }
        try await waitUntil { coordinator.current?.id == request.id }

        #expect(await task.value == .timedOut)
        #expect(coordinator.pending.isEmpty)
    }

    @Test(.requiresVisibleWindow)
    func queuedSecretDoesNotSpendItsTimeoutBehindSSHPrompt() async throws {
        let coordinator = ExternalAuthCoordinator()
        let sshRequest = authenticationRequest(name: "Current")
        let request = secretRequest(timeout: .milliseconds(40))
        let ssh = Task {
            await coordinator.enqueue(sshRequest, clientName: "Claude", runID: UUID())
        }
        try await waitUntil { coordinator.current?.id == sshRequest.id }
        let secret = Task {
            await coordinator.enqueue(request, clientName: "Codex", runID: UUID())
        }
        try await waitUntil { coordinator.pending.count == 2 }

        try await Task.sleep(for: .milliseconds(80))
        #expect(coordinator.current?.id == sshRequest.id)
        #expect(coordinator.pending.contains { $0.id == request.id })

        coordinator.respondSSH(.cancelled)
        #expect(await ssh.value == .cancelled)
        #expect(coordinator.current?.id == request.id)
        #expect(await secret.value == .timedOut)
        #expect(coordinator.pending.isEmpty)
    }

    @Test(.requiresVisibleWindow)
    func answeredSecretCannotLaterRetireANewerPopup() async throws {
        let coordinator = ExternalAuthCoordinator()
        let request = secretRequest(timeout: .milliseconds(40))
        let secret = Task {
            await coordinator.enqueue(request, clientName: "Claude", runID: UUID())
        }
        try await waitUntil { coordinator.current?.id == request.id }
        coordinator.respondSecret(
            .answered([
                AgentUserInputAnswer(
                    questionID: "secret", value: .secret(agentSecret("value"))
                )
            ]))
        guard case .answered = await secret.value else {
            Issue.record("expected the secret request to be answered")
            return
        }

        let sshRequest = authenticationRequest(name: "Next")
        let ssh = Task {
            await coordinator.enqueue(sshRequest, clientName: "Codex", runID: UUID())
        }
        try await waitUntil { coordinator.current?.id == sshRequest.id }
        try await Task.sleep(for: .milliseconds(80))
        #expect(coordinator.current?.id == sshRequest.id)

        coordinator.respondSSH(.cancelled)
        #expect(await ssh.value == .cancelled)
    }

    @Test(.requiresVisibleWindow)
    func hostKeyUsesPopupQueueAndReturnsSelectedTrustScope() async throws {
        let coordinator = ExternalAuthCoordinator()
        let request = hostKeyRequest()
        let task = Task {
            await coordinator.enqueue(
                request, clientName: "Claude Code", runID: UUID()
            )
        }
        try await waitUntil {
            if case .hostKey? = coordinator.current?.request { return true }
            return false
        }

        #expect(coordinator.current?.clientName == "Claude Code")
        coordinator.respondHostKey(.trustAndContinue)

        #expect(await task.value == .trustAndContinue)
        #expect(coordinator.pending.isEmpty)
    }

    @Test(.requiresVisibleWindow)
    func closingHostKeyPopupDeniesTheWaitingCall() async throws {
        let coordinator = ExternalAuthCoordinator()
        let task = Task {
            await coordinator.enqueue(
                hostKeyRequest(), clientName: "Codex", runID: UUID()
            )
        }
        try await waitUntil {
            if case .hostKey? = coordinator.current?.request { return true }
            return false
        }

        coordinator.windowClosed()

        #expect(await task.value == .deny)
        #expect(coordinator.pending.isEmpty)
    }
}

@Suite(.serialized)
@MainActor
struct ExternalToolCallHistoryTests {
    @Test(arguments: [nil, "uname"])
    func clearingHistoryInvalidatesObservedEntriesImmediately(filter: String?) {
        let entry = ExternalToolCall(
            runID: UUID(), clientName: "Claude Code", toolName: "ssh_exec",
            summary: "uname -a", risk: .readOnly,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let store = ToolAuditModel(entries: [entry])
        let invalidated = ObservationInvalidationFlag()
        func observedEntries() -> [ExternalToolCall] {
            filter.map { store.entries(matching: $0) } ?? store.entries()
        }

        withObservationTracking {
            #expect(observedEntries().map(\.id) == [entry.id])
        } onChange: {
            invalidated.value = true
        }

        store.clear()

        #expect(invalidated.value)
        #expect(observedEntries().isEmpty)
    }

    @Test
    func sftpBodiesAndSSHOutputNeverEnterHistory() async throws {
        let channel = AgentEventChannel(repository: InMemoryAgentRunRepository())
        let store = ToolAuditModel()
        store.consume(channel)
        let runID = UUID()
        store.register(runID: runID, clientName: "Claude Code")

        let write = invocation(
            runID: runID, name: "sftp_write",
            arguments: ["path": .string("/srv/config"), "content": .string("TOP-SECRET")]
        )
        channel.emit(.toolProposed(write, descriptor(name: "sftp_write", readOnly: false)))
        channel.emit(
            .toolFinished(
                write,
                untrustedResult(
                    callID: write.call.id, payload: .object(["bytes": .number(10)])
                )))

        let exec = invocation(
            runID: runID, name: "ssh_exec", arguments: ["command": .string("uname -a")]
        )
        channel.emit(.toolProposed(exec, descriptor(name: "ssh_exec", readOnly: false)))
        channel.emit(
            .toolFinished(
                exec,
                untrustedResult(
                    callID: exec.call.id,
                    payload: .object(["stdout": .string("PRIVATE OUTPUT"), "exit_code": .number(0)])
                )))
        try await waitUntil {
            let rows = store.entries()
            return rows.count == 2 && rows.allSatisfy { $0.status != .running }
        }

        let rows = store.entries()
        let writeRow = try #require(rows.first { $0.toolName == "sftp_write" })
        #expect(writeRow.summary == "/srv/config")
        #expect(writeRow.bytesWritten == 10)
        #expect(!writeRow.summary.contains("TOP-SECRET"))
        let execRow = try #require(rows.first { $0.toolName == "ssh_exec" })
        #expect(execRow.summary == "uname -a")
        #expect(execRow.exitCode == 0)
        #expect(!execRow.summary.contains("PRIVATE OUTPUT"))
    }

    @Test
    func inMemoryHistoryKeepsTheNewestTwoThousandRows() {
        let start = Date(timeIntervalSince1970: 1_000)
        let entries = (0...ToolAuditModel.globalLimit).map { index in
            ExternalToolCall(
                runID: UUID(), clientName: "Client", toolName: "list_hosts",
                summary: "row-\(index)", risk: .readOnly,
                startedAt: start.addingTimeInterval(Double(index))
            )
        }
        let store = ToolAuditModel(entries: entries)
        let kept = store.entries()

        #expect(kept.count == ToolAuditModel.globalLimit)
        #expect(kept.first?.summary == "row-2000")
        #expect(kept.last?.summary == "row-1")
    }
}

nonisolated private final class ObservationInvalidationFlag: @unchecked Sendable {
    var value = false
}

private func authenticationRequest(name: String) -> AgentSSHAuthenticationRequest {
    AgentSSHAuthenticationRequest(
        invocationID: UUID(), hostID: UUID(), displayName: name,
        address: "host.example", mode: .identity, username: "root"
    )
}

private func secretRequest(timeout: Duration) -> AgentUserInputRequest {
    AgentUserInputRequest(
        questions: [AgentUserQuestion(id: "secret", prompt: "Secret", kind: .secret)],
        purpose: "test", timeout: timeout
    )
}

private func hostKeyRequest() -> AgentSSHHostKeyRequest {
    let observation = SSHHostKeyObservation(
        hostname: "host.example", port: 22, algorithm: .ed25519,
        fingerprint: "SHA256:new"
    )
    return AgentSSHHostKeyRequest(
        invocationID: UUID(), hostID: UUID(), displayName: "Host",
        address: "host.example",
        prompt: SSHHostKeyPrompt(observation: observation, kind: .firstUse),
        allowsPersistentTrust: true
    )
}

private func invocation(
    runID: UUID, name: String, arguments: [String: AgentJSONValue]
) -> AgentToolInvocation {
    AgentToolInvocation(
        runID: runID,
        call: AgentToolCall(id: UUID().uuidString, name: name, arguments: .object(arguments)),
        targetHostID: UUID()
    )
}

private func descriptor(name: String, readOnly: Bool) -> AgentToolDescriptor {
    AgentToolDescriptor(
        name: name, summary: name,
        inputSchema: .object(["type": .string("object")]), target: .host,
        approvalPolicy: readOnly ? .approve : .ask
    )
}

private func untrustedResult(callID: String, payload: AgentJSONValue) -> AgentToolResult {
    AgentToolResult(
        callID: callID,
        content: AgentToolResult.untrustedDataOpeningMarker + payload.encodedString
            + AgentToolResult.untrustedDataClosingMarker,
        metadata: ["untrusted": .bool(true)]
    )
}

@MainActor
private func waitUntil(
    _ condition: @MainActor () -> Bool
) async throws {
    for _ in 0..<100 {
        if condition() { return }
        await Task.yield()
    }
    throw ExternalRequestTestFailure.timedOut
}

private enum ExternalRequestTestFailure: Error { case timedOut }
