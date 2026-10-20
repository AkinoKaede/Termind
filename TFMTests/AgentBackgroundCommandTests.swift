// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindRemoteInfrastructure
import Testing

private nonisolated func exited(_ code: Int32 = 0) -> SSHExecResult {
    SSHExecResult(
        stdout: "", stderr: "", exitCode: code, signal: nil,
        stdoutTruncated: false, stderrTruncated: false)
}

@Suite
struct AgentBackgroundCommandTests {
    @Test
    func outputToolCapturesEachFullSnapshotWithItsOwnNameUnderTheConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = AgentScratchWorkspace(base: directory)
        let scope = UUID()
        let accumulator = AgentOutputAccumulator(
            workspace: workspace,
            path: {
                "\(scope.uuidString.lowercased())/outputs/ssh-exec-\(UUID().uuidString.lowercased()).txt"
            })
        let stream = AgentCommandOutputStream(accumulator: accumulator) { _, _ in }
        let commands = AgentBackgroundCommands(sweepInterval: nil)
        let source = "first\n" + String(repeating: "output\n", count: 2_100) + "last>"
        let handle = try await commands.start(
            scope: scope, hostID: UUID(), command: "build", keepsStdinOpen: false, stream: stream
        ) { session in
            session.start { _ in 0 }
            stream.handler(Data(source.utf8), false)
            return exited()
        }
        try await commands.waitForCompletion(handle, scope: scope)
        let run = await stream.snapshot()
        #expect(run.capture?.path?.hasPrefix("\(scope.uuidString.lowercased())/outputs/ssh-exec-") == true)
        let tool = SSHExecOutputTool(background: commands, scope: scope)
        let call = AgentToolInvocation(
            runID: UUID(),
            call: .init(
                id: "output", name: "ssh_exec_output",
                arguments: .object([
                    "handle": .string(handle.uuidString)
                ])))
        let context = AgentToolExecutionContext(
            runID: call.runID, conversationID: scope, userIntent: "read output", secretBroker: SecretBroker(),
            userInteraction: UnavailableAgentUserInteraction(), preflightMetadata: [:],
            authorize: { _ in .allow }, workspace: workspace)
        let first = try await tool.execute(call, context: context)
        let second = try await tool.execute(call, context: context)
        let path = try #require(first.outputCapture?.path)
        #expect(path.hasPrefix("\(scope.uuidString.lowercased())/outputs/ssh-exec-output-"))
        #expect(path.hasSuffix(".txt"))
        #expect(second.outputCapture?.path != path)
        #expect(try await workspace.data(at: path).data == Data(source.utf8))
        #expect(first.metadata["output_total_lines"] == .number(2_102))
        await commands.closeAll()
    }

    @Test
    func outputIsImmediateCumulativeAndRepeatableAfterCompletion() async throws {
        let commands = AgentBackgroundCommands(sweepInterval: nil)
        let scope = UUID()
        let release = AsyncRelease()
        let stream = AgentCommandOutputStream(
            accumulator: AgentOutputAccumulator(path: { "tests/outputs/ssh-exec-\(UUID().uuidString).txt" })
        ) { _, _ in }
        let handle = try await commands.start(
            scope: scope, hostID: UUID(), command: "build", keepsStdinOpen: false, stream: stream
        ) { session in
            session.start { _ in 0 }
            await release.wait()
            return exited(7)
        }
        stream.handler(Data("step one\n".utf8), false)
        let running = try await commands.output(handle, scope: scope)
        #expect(running.objectValue?["status"] == .string("running"))
        #expect(running.objectValue?["output"] == .string("step one\n"))
        #expect(running.objectValue?["stdin_closed"] == .bool(true))
        #expect(try await commands.output(handle, scope: scope) == running)

        stream.handler(Data("step two\n".utf8), false)
        stream.handler(Data("failure\n".utf8), true)
        await release.release()
        try await commands.waitForCompletion(handle, scope: scope)
        let finished = try await commands.output(handle, scope: scope)
        #expect(finished.objectValue?["status"] == .string("exited"))
        #expect(finished.objectValue?["exit_code"] == .number(7))
        #expect(finished.objectValue?["output"] == .string("step one\nstep two\nfailure\n"))
        #expect(try await commands.output(handle, scope: scope) == finished)
        #expect(await commands.count == 1)
        await commands.closeAll()
    }

    @Test
    func failedStartupLeavesNoHandle() async {
        let commands = AgentBackgroundCommands(sweepInterval: nil)
        await #expect(throws: CocoaError.self) {
            try await commands.start(
                scope: UUID(), hostID: UUID(), command: "build", keepsStdinOpen: true,
                stream: AgentCommandOutputStream(
                    accumulator: AgentOutputAccumulator(path: { "tests/outputs/ssh-exec-\(UUID().uuidString).txt" })
                ) { _, _ in }
            ) { _ in throw CocoaError(.fileReadNoPermission) }
        }
        #expect(await commands.count == 0)
    }

    @Test
    func cancellationDuringStartupDoesNotWaitForAuthenticationOrAllowLateStartup() async throws {
        let commands = AgentBackgroundCommands(sweepInterval: nil)
        let scope = UUID()
        let connecting = AsyncRelease()
        let release = AsyncRelease()
        let finished = AsyncRelease()
        let task = Task {
            try await commands.start(
                scope: scope, hostID: UUID(), command: "build", keepsStdinOpen: true,
                stream: AgentCommandOutputStream(
                    accumulator: AgentOutputAccumulator(path: { "tests/outputs/ssh-exec-\(UUID().uuidString).txt" })
                ) { _, _ in }
            ) { session in
                await connecting.release()
                await release.wait()
                session.start { _ in 0 }
                #expect(!session.started)
                await finished.release()
                return exited()
            }
        }
        await connecting.wait()
        #expect(await commands.list(scope: scope).objectValue?["commands"] == .array([]))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await commands.count == 0)
        await release.release()
        await finished.wait()
    }

    @Test
    func runningCommandsNeverExpireAndFinishedReadsDoNotExtendRetention() async throws {
        let commands = AgentBackgroundCommands(idleTimeout: .seconds(600), sweepInterval: nil)
        let scope = UUID()
        let release = AsyncRelease()
        let handle = try await commands.start(
            scope: scope, hostID: UUID(), command: "build", keepsStdinOpen: true,
            stream: AgentCommandOutputStream(
                accumulator: AgentOutputAccumulator(path: { "tests/outputs/ssh-exec-\(UUID().uuidString).txt" })
            ) { _, _ in }
        ) { session in
            session.start { _ in 0 }
            await release.wait()
            return exited()
        }
        #expect(await commands.sweepIdle(now: .now.advanced(by: .seconds(86_400))) == 1)
        await release.release()
        try await commands.waitForCompletion(handle, scope: scope)
        _ = try await commands.output(handle, scope: scope)
        #expect(await commands.list(scope: scope).objectValue?["commands"] == .array([]))
        #expect(
            await commands.list(scope: scope, includeFinished: true).objectValue?["commands"]?.arrayValue?.count == 1)
        #expect(await commands.sweepIdle(now: .now.advanced(by: .seconds(601))) == 0)
        await #expect(throws: AgentBackgroundCommandError.self) {
            try await commands.output(handle, scope: scope)
        }
    }

    @Test
    func scopeIsolationAndCancellationRetireOnlyTheLocalHandle() async throws {
        let commands = AgentBackgroundCommands(sweepInterval: nil)
        let scope = UUID()
        let otherScope = UUID()
        let host = UUID()
        let release = AsyncRelease()
        let handle = try await commands.start(
            scope: scope, hostID: host, command: "build", keepsStdinOpen: true,
            stream: AgentCommandOutputStream(
                accumulator: AgentOutputAccumulator(path: { "tests/outputs/ssh-exec-\(UUID().uuidString).txt" })
            ) { _, _ in }
        ) { session in
            session.start { _ in 0 }
            await release.wait()
            return exited()
        }
        #expect(await commands.list(scope: otherScope).objectValue?["commands"] == .array([]))
        #expect(await commands.list(scope: scope, hostID: UUID()).objectValue?["commands"] == .array([]))
        let rows = await commands.list(scope: scope, hostID: host).objectValue?["commands"]?.arrayValue
        #expect(rows?.count == 1)
        #expect(rows?.first?.objectValue?["output"] == nil)
        await #expect(throws: AgentBackgroundCommandError.self) {
            try await commands.cancel(handle, scope: otherScope)
        }
        let result = try await commands.cancel(handle, scope: scope)
        #expect(result.objectValue?["status"] == .string("cancelled"))
        #expect(result.objectValue?["was_running"] == .bool(true))
        #expect(result.objectValue?["remote_termination_confirmed"] == .bool(false))
        await #expect(throws: AgentBackgroundCommandError.self) {
            try await commands.cancel(handle, scope: scope)
        }
        await release.release()
        #expect(await commands.count == 0)
    }

    @Test
    func stdinPreservesExactBytesAndEOFIsIdempotent() async throws {
        let commands = AgentBackgroundCommands(sweepInterval: nil)
        let scope = UUID()
        let release = AsyncRelease()
        let writes = InputLog()
        let handle = try await commands.start(
            scope: scope, hostID: UUID(), command: "cat", keepsStdinOpen: true,
            stream: AgentCommandOutputStream(
                accumulator: AgentOutputAccumulator(path: { "tests/outputs/ssh-exec-\(UUID().uuidString).txt" })
            ) { _, _ in }
        ) { session in
            session.start { try await writes.write($0) }
            await release.wait()
            return exited()
        }
        let result = try await commands.write(handle, scope: scope, input: .text("abc"))
        #expect(result.objectValue?["bytes_written"] == .number(3))
        _ = try await commands.write(handle, scope: scope, input: .text(""))
        _ = try await commands.write(handle, scope: scope, input: nil)
        let repeated = try await commands.write(handle, scope: scope, input: nil)
        #expect(repeated.objectValue?["stdin_closed"] == .bool(true))
        #expect(await writes.values == ["abc", "", nil])
        await #expect(throws: (any Error).self) {
            try await commands.write(handle, scope: scope, input: .text("too late"))
        }
        await release.release()
        try await commands.waitForCompletion(handle, scope: scope)
        #expect(try await commands.cancel(handle, scope: scope).objectValue?["status"] == .string("released"))
    }

    @Test
    func interjectionReturnsRunningSnapshotWithoutCancellingCommand() async throws {
        let commands = AgentBackgroundCommands(sweepInterval: nil)
        let scope = UUID()
        let release = AsyncRelease()
        let signal = AgentInterjectionSignal()
        let handle = try await commands.start(
            scope: scope, hostID: UUID(), command: "build", keepsStdinOpen: false,
            stream: AgentCommandOutputStream(
                accumulator: AgentOutputAccumulator(path: { "tests/outputs/ssh-exec-\(UUID().uuidString).txt" })
            ) { _, _ in }
        ) { session in
            session.start { _ in 0 }
            await release.wait()
            #expect(!Task.isCancelled)
            return exited()
        }
        signal.arm()
        try await commands.waitForCompletion(handle, scope: scope, interjection: { await signal.wait() })
        #expect(try await commands.output(handle, scope: scope).objectValue?["status"] == .string("running"))
        await release.release()
        try await commands.waitForCompletion(handle, scope: scope)
        await commands.closeAll()
    }

    @Test
    func outputAndListAreReadOnlyParallelToolsWithoutTimeouts() {
        let commands = AgentBackgroundCommands(sweepInterval: nil)
        let scope = UUID()
        let tools = [
            AnyAgentTool(SSHExecOutputTool(background: commands, scope: scope)),
            AnyAgentTool(SSHExecListTool(background: commands, scope: scope)),
        ]
        for tool in tools {
            #expect(tool.descriptor.approvalPolicy == .approve)
            #expect(tool.descriptor.concurrency == .parallel)
            #expect(tool.descriptor.inputSchema.objectValue?["properties"]?.objectValue?["timeout_seconds"] == nil)
        }
    }

    @Test(arguments: ["text", "empty", "secret", "eof"], [false, true])
    func stdinToolAcceptsOmittedOrNullUnusedPayloads(mode: String, explicitNulls: Bool) async throws {
        let secretText = "stdin-regression-secret"
        let commands = AgentBackgroundCommands(sweepInterval: nil)
        let scope = UUID()
        let hostID = UUID()
        let release = AsyncRelease()
        let writes = InputLog()
        let handle = try await commands.start(
            scope: scope, hostID: hostID, command: "cat", keepsStdinOpen: true,
            stream: AgentCommandOutputStream(
                accumulator: AgentOutputAccumulator(path: { "tests/outputs/ssh-exec-\(UUID().uuidString).txt" })
            ) { _, _ in }
        ) { session in
            session.start { try await writes.write($0) }
            await release.wait()
            return exited()
        }
        let broker = SecretBroker()
        do {
            let tool = SSHExecStdinTool(background: commands, scope: scope)
            var arguments: [String: AgentJSONValue] = [
                "handle": .string(handle.uuidString), "type": .string(mode == "empty" ? "text" : mode),
            ]
            if explicitNulls {
                arguments["stdin"] = .null
                arguments["secret_handle"] = .null
            }
            switch mode {
            case "text", "empty": arguments["stdin"] = .string(mode == "empty" ? "" : "input")
            case "secret":
                var bytes = Data(secretText.utf8)
                let secret = try await broker.issue(AgentSecret(consumingUTF8: &bytes))
                arguments["secret_handle"] = .string(secret.id.uuidString)
            default: break
            }
            let invocation = AgentToolInvocation(
                runID: UUID(), call: .init(id: "stdin", name: "ssh_exec_stdin", arguments: .object(arguments)),
                targetHostID: UUID())
            try AgentJSONSchemaValidator.validate(invocation.call.arguments, against: tool.descriptor.inputSchema)
            let checked = try await tool.preflight(invocation)
            #expect(checked.invocation.targetHostID == hostID)
            #expect(checked.approvalPolicy == .ask)
            let review = GuardianPolicy.reviewPrompt(
                .init(
                    invocation: checked.invocation, descriptor: tool.descriptor, userIntent: "Provide command input",
                    localReasons: checked.reasons),
                evidence: [])
            #expect(review.contains(hostID.uuidString))
            #expect(review.contains("Write input to: cat"))
            #expect(review.contains("The plaintext is intentionally hidden from review") == (mode == "secret"))
            #expect(!review.contains(secretText))
            if mode == "secret" {
                #expect(await broker.count == 1)
                #expect(await writes.secretWrites == 0)
            }
            let result = try await tool.execute(
                checked.invocation,
                context: .init(
                    runID: invocation.runID, userIntent: "Provide command input", secretBroker: broker,
                    userInteraction: UnavailableAgentUserInteraction(), preflightMetadata: [:],
                    authorize: { _ in .allow }))
            let payload = try AgentJSONValue.decode(Data(try #require(result.untrustedPayload).utf8))
            #expect(!result.isError)
            #expect(payload.objectValue?["status"] == .string(mode == "eof" ? "closed" : "written"))
            #expect(payload.objectValue?["stdin_closed"] == .bool(mode == "eof"))
            switch mode {
            case "text": #expect(await writes.values == ["input"])
            case "empty": #expect(await writes.values == [""])
            case "secret":
                #expect(await writes.secretWrites == 1)
                #expect(await broker.count == 0)
                #expect(payload.objectValue?["bytes_written"] == .number(Double(secretText.utf8.count)))
            default: #expect(await writes.values == [nil])
            }
        } catch {
            await release.release()
            await commands.closeAll()
            await broker.discardAll()
            throw error
        }
        await release.release()
        await commands.closeAll()
    }

    @Test(arguments: [false, true])
    func listToolAcceptsOmittedOrNullFilters(explicitNulls: Bool) async throws {
        let tool = SSHExecListTool(background: AgentBackgroundCommands(sweepInterval: nil), scope: UUID())
        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: .init(
                id: "list", name: "ssh_exec_list",
                arguments: .object(explicitNulls ? ["host_id": .null, "include_finished": .null] : [:])))
        try AgentJSONSchemaValidator.validate(invocation.call.arguments, against: tool.descriptor.inputSchema)
        let result = try await tool.execute(
            invocation,
            context: .init(
                runID: invocation.runID, userIntent: "List commands", secretBroker: SecretBroker(),
                userInteraction: UnavailableAgentUserInteraction(), preflightMetadata: [:], authorize: { _ in .allow }))
        let payload = try AgentJSONValue.decode(Data(try #require(result.untrustedPayload).utf8))
        #expect(payload == .object(["commands": .array([])]))
    }

    @Test(arguments: [
        ["type": AgentJSONValue.string("text"), "stdin": .null, "secret_handle": .null],
        ["type": .string("secret"), "stdin": .null, "secret_handle": .null],
        ["type": .string("secret"), "stdin": .null, "secret_handle": .string("invalid")],
        ["type": .string("text"), "stdin": .string("input"), "secret_handle": .string(UUID().uuidString)],
        ["type": .string("secret"), "stdin": .string(""), "secret_handle": .string(UUID().uuidString)],
        ["type": .string("eof"), "stdin": .string(""), "secret_handle": .null],
        ["type": .string("eof"), "stdin": .null, "secret_handle": .string(UUID().uuidString)],
        ["type": .string("eof"), "stdin": .bool(false), "secret_handle": .null],
    ])
    func stdinToolStillRejectsMissingRequiredOrConflictingPayloads(arguments: [String: AgentJSONValue]) async {
        let tool = SSHExecStdinTool(background: AgentBackgroundCommands(sweepInterval: nil), scope: UUID())
        var arguments = arguments
        arguments["handle"] = .string(UUID().uuidString)
        let invocation = AgentToolInvocation(
            runID: UUID(), call: .init(id: "stdin", name: "ssh_exec_stdin", arguments: .object(arguments)))
        do {
            _ = try await tool.preflight(invocation)
            Issue.record("Invalid input must be rejected before command lookup")
        } catch AgentToolError.invalidArguments {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private actor AsyncRelease {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor InputLog {
    var values: [String?] = []
    var secretWrites = 0
    func write(_ input: SSHCommandInput?) throws -> Int {
        switch input {
        case .text(let text):
            values.append(text)
            return text.utf8.count
        case .plain(let data):
            values.append(String(decoding: data, as: UTF8.self))
            return data.count
        case nil:
            values.append(nil)
            return 0
        case .secret(let secret):
            secretWrites += 1
            return try secret.withUnsafeBytes { $0.count }
        }
    }
}
