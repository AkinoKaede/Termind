import Foundation
import Testing

@testable import Termind

@Suite(.serialized)
@MainActor
struct ExternalAuthCoordinatorTests {
    @Test
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

    @Test
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

    @Test
    func secretRequestsUseTheSamePopupQueueAndRejectOrdinaryQuestions() async throws {
        let coordinator = ExternalAuthCoordinator()
        let runID = UUID()
        let request = AgentUserInputRequest(
            questions: [AgentUserQuestion(id: "secret", prompt: "Password", kind: .secret)],
            purpose: "sudo", hostID: UUID()
        )
        let task = Task {
            await coordinator.enqueue(request, clientName: "Claude", runID: runID)
        }
        try await waitUntil {
            if case .secret? = coordinator.current?.request { return true }
            return false
        }

        coordinator.respondSecret(.answered([
            AgentUserInputAnswer(questionID: "secret", value: .secret("value"))
        ]))
        #expect(await task.value == .answered([
            AgentUserInputAnswer(questionID: "secret", value: .secret("value"))
        ]))

        let ordinary = AgentUserInputRequest(
            questions: [AgentUserQuestion(id: "text", prompt: "Name", kind: .text)]
        )
        #expect(
            await coordinator.enqueue(ordinary, clientName: "Claude", runID: runID)
                == .cancelled
        )
    }

    @Test
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
}

@Suite(.serialized)
@MainActor
struct ExternalToolCallHistoryTests {
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
        channel.emit(.toolFinished(write, untrustedResult(
            callID: write.call.id, payload: .object(["bytes": .number(10)])
        )))

        let exec = invocation(
            runID: runID, name: "ssh_exec", arguments: ["command": .string("uname -a")]
        )
        channel.emit(.toolProposed(exec, descriptor(name: "ssh_exec", readOnly: false)))
        channel.emit(.toolFinished(exec, untrustedResult(
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

private func authenticationRequest(name: String) -> AgentSSHAuthenticationRequest {
    AgentSSHAuthenticationRequest(
        invocationID: UUID(), hostID: UUID(), displayName: name,
        address: "host.example", mode: .identity, username: "root"
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
        safety: readOnly ? .locallyReadOnly : .requiresAuthorization
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
