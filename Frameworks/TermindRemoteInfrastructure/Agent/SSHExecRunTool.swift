// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindDomain

nonisolated public struct SSHExecRunTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.ssh_exec_run",
        layout: .init(singleLineHeader: true, boundsApprovalHeight: true, truncateStrategy: .tail),
        present: { AgentToolDetailFormatting.genericItems($0.result, locale: $0.locale) },
        presentArguments: presentArguments)
    public let authentication: AgentSSHAuthenticationRegistry
    public let pool: AgentConnectionPool
    public let background: AgentBackgroundCommands
    public let scope: UUID
    public var truncateStrategy: AgentTruncateStrategy { .tail }

    public init(
        authentication: AgentSSHAuthenticationRegistry, pool: AgentConnectionPool,
        background: AgentBackgroundCommands, scope: UUID = UUID()
    ) {
        self.authentication = authentication
        self.pool = pool
        self.background = background
        self.scope = scope
    }

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            TermindToolName.sshExecRun,
            """
            Run a non-PTY SSH command. Discover host_id with list_hosts when needed; Termind handles login. \
            run_in_background defaults to false: wait for completion without a runtime timeout and close stdin. \
            Set true for long-lived commands or commands needing ssh_exec_stdin; return after confirmed startup. \
            Returns handle, host_id, status (running/exited/failed), combined output, exit_code, signal, \
            stdin_closed and error. Model output keeps the latest complete lines within 64 KiB / 2000 lines. \
            Truncated output is saved to <conversationID>/outputs/ssh-exec-<UUID>.txt in shared scratch; \
            use scratch_read or scratch_search with that exact path. Capture failures are explicit. \
            Handles belong to this conversation/session; finished results remain for ten minutes. \
            Use ssh_exec_output for snapshots and ssh_exec_cancel for local cleanup. Never include plaintext secrets.
            """,
            properties: [
                "host_id": Self.string(max: 64), "command": Self.string(max: 32_768),
                "run_in_background": Self.boolean(),
            ], required: ["host_id", "command"], target: .host, approvalPolicy: .ask,
            presentation: .init(
                symbol: "terminal",
                activity: .semanticArgument(key: "command", fallback: .sshCommand),
                output: .field("output"),
                actionKind: .run,
                phaseKinds: [
                    "proposed": .sshPreparingCommand,
                    "waitingForApproval": .sshWaitingForCommand,
                    "waitingForUser": .sshWaitingForAuthentication,
                    "running": .sshConnecting,
                    "command": .sshRunningCommand,
                    "completed": .sshCompletedCommand,
                    "denied": .sshDeniedCommand,
                    "failed": .sshFailedCommand,
                    "interrupted": .sshInterruptedCommand,
                ],
                messages: [
                    "proposed": "Preparing to run {activity} on {target}",
                    "waitingForApproval": "Waiting to run {activity} on {target}",
                    "waitingForUser": "Waiting to authenticate with {target}",
                    "running": "Connecting to {target}",
                    "command": "Running {activity} on {target}",
                    "completed": "Ran {activity} on {target}",
                    "denied": "Did not run {activity} on {target}",
                    "failed": "Failed to run {activity} on {target}",
                    "interrupted": "Stopped waiting for {activity} on {target}",
                ]
            )
        )
    }

    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        let arguments = try Arguments(invocation)
        var checked = invocation
        checked.targetHostID = try arguments.uuid("host_id")
        let command = try arguments.string("command")
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.invalidArguments("command must not be empty.")
        }
        let assessment = CommandRiskClassifier.assess(command)
        let safe = assessment.risk == .safe
        return .init(
            invocation: checked, approvalPolicy: safe ? .approve : .ask,
            reasons: assessment.reasons, concurrency: safe ? .parallel : .sequential)
    }

    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let arguments = try Arguments(invocation)
        let hostID = try arguments.uuid("host_id")
        let command = try arguments.string("command")
        let isBackground = arguments.optionalBool("run_in_background") ?? false
        let accumulator = context.makeOutputAccumulator {
            "\(scope.uuidString.lowercased())/outputs/ssh-exec-\(UUID().uuidString.lowercased()).txt"
        }
        let stream = AgentCommandOutputStream(accumulator: accumulator) { out, _ in
            var result = Self.result(
                invocation,
                .object([
                    "status": .string("running"), "output": .string(out),
                ]))
            result.metadata["presentation_phase"] = .string("command")
            context.report(result)
        }
        let handle = try await background.start(
            scope: scope, hostID: hostID, command: command, keepsStdinOpen: isBackground, stream: stream
        ) { session in
            var connection = try await authentication.connectionContext(
                hostID: hostID, invocationID: invocation.id, interaction: context.sshInteraction, pool: pool)
            var retried = false
            while true {
                try Task.checkCancellation()
                let ssh = connection.connection
                do {
                    return try await pool.withExecLease(hostID: hostID, connection: ssh) {
                        try await ssh.executeSession(command, session: session, onOutput: stream.handler)
                    }
                } catch SSHCommandExecutionError.connectionUnavailable where !retried && !session.started {
                    retried = true
                    await pool.disconnect(hostID: hostID)
                    connection.connection = try await authentication.openConnection(
                        hostID: hostID, authentication: connection.authentication, pool: pool)
                }
            }
        }
        if !isBackground {
            let interjection: (@Sendable () async -> Void)?
            if context.services[.sshInterjectionEnabled] == true {
                interjection = { await context.whenUserInterjects() }
            } else {
                interjection = nil
            }
            do {
                try await background.waitForCompletion(
                    handle, scope: scope, interjection: interjection)
            } catch {
                _ = try? await background.cancel(handle, scope: scope)
                throw error
            }
        }
        return SSHExecResults.snapshot(invocation, try await background.output(handle, scope: scope))
    }

    public static func presentArguments(_ input: AgentToolArgumentDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        var items: [AgentToolDetail.Item] = []
        if let command = input.arguments["command"]?.stringValue {
            items.append(
                .text(
                    .init(
                        title: F.localized("Command", locale: input.locale), text: command,
                        style: .monospaced, isCollapsible: false)))
        }
        // Retained only for historical cards, not accepted by the executable schema.
        F.appendField(
            &items, "Working directory", input.arguments["cwd"]?.stringValue,
            locale: input.locale, monospaced: true)
        return items
    }
}
