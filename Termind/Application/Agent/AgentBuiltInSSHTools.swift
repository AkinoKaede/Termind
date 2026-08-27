import Foundation

nonisolated extension AgentBuiltInTools {
    static func listHosts(_ hosts: AgentHostResolver) -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "list_hosts", "List Vault and temporary Termind SSH targets without credentials.",
            properties: [:], required: [], target: .host, safety: .locallyReadOnly,
            concurrency: .parallel,
            presentation: .init(
                symbol: "server.rack", activity: .semanticLabel(.hosts), output: .json,
                actionKind: .list
            )
        )) { invocation, _ in
            let listing = await hosts.listing()
            let rows = listing.hosts.map { target in
                AgentJSONValue.object([
                    "id": .string(target.id.uuidString), "display_name": .string(target.displayName),
                    "address": .string(target.address), "tags": .array(target.tags.map(AgentJSONValue.string)),
                    "connection_state": .string(target.connectionState),
                    "temporary": .bool(target.isTemporary),
                    "group_id": target.groupID.map { .string($0.uuidString) } ?? .null,
                    "group_path": target.groupPath.map(AgentJSONValue.string) ?? .null,
                ])
            }
            func groupJSON(_ group: AgentHostGroupTarget) -> AgentJSONValue {
                .object([
                    "id": .string(group.id.uuidString), "name": .string(group.name),
                    "path": .string(group.path),
                    "children": .array(group.children.map(groupJSON)),
                ])
            }
            return result(invocation, .object([
                "groups": .array(listing.groups.map(groupJSON)),
                "hosts": .array(rows),
            ]))
        }
    }

    /// How long `ssh_exec` waits before telling the model what it has.
    ///
    /// Short, and safe to be short only because expiry stopped being
    /// destructive. It used to throw, discard the session, and lose everything
    /// the command had printed — while the command itself carried on running on
    /// the host — so the default had to be generous enough that it rarely
    /// happened. Now it hands back the output and a handle, which makes a short
    /// deadline pure gain: turns end in seconds, and anything the user typed
    /// while waiting is delivered at the boundary that follows.
    private static let defaultReportingDeadline = 15

    /// The ceiling on how long a command may run at all, deadline or no. Matches
    /// the clamp the session's own pump applies.
    private static let maximumCommandLifetime: TimeInterval = 15 * 60

    /// The sink that turns captured output into progress on this call's card.
    private static func reporting(
        _ invocation: AgentToolInvocation,
        _ report: @escaping @Sendable (AgentToolResult) -> Void
    ) -> @Sendable (String, String) -> Void {
        { out, error in
            var progress = result(invocation, .object([
                "status": .string("running"),
                "stdout": .string(out), "stderr": .string(error),
            ]))
            progress.metadata["presentation_phase"] = .string("command")
            report(progress)
        }
    }

    private static func exitedResult(
        _ invocation: AgentToolInvocation, _ output: SSHExecResult
    ) -> AgentToolResult {
        result(invocation, .object([
            "status": .string("exited"),
            "stdout": .string(output.stdout), "stderr": .string(output.stderr),
            "exit_code": .number(Double(output.exitCode)),
            "signal": output.signal.map(AgentJSONValue.string) ?? .null,
            "stdout_truncated": .bool(output.stdoutTruncated),
            "stderr_truncated": .bool(output.stderrTruncated),
        ]), truncated: output.stdoutTruncated || output.stderrTruncated)
    }

    /// Picks up a command `ssh_exec` left running.
    ///
    /// Read-only and parallel: it looks at a buffer and a task, and touches the
    /// host not at all. While it waits, the command's output is redirected to
    /// *this* call's card — output belongs under whichever call is currently
    /// answering for it, never two at once and never none.
    static func sshWait(_ background: AgentBackgroundCommands) -> AnyAgentTool {
        AnyAgentTool(
            descriptor: descriptor(
                "ssh_wait",
                "Wait for a command ssh_exec reported as still running, and return its output.",
                properties: [
                    "handle": string(max: 64),
                    "timeout_seconds": integer(min: 1, max: 900),
                ],
                required: ["handle"], target: .host, safety: .locallyReadOnly,
                concurrency: .parallel,
                presentation: .init(
                    symbol: "clock.arrow.circlepath",
                    activity: .semanticLabel(.remoteCommand), output: .streams,
                    actionKind: .wait
                )
            ),
            execute: { invocation, context in
                let arguments = try Arguments(invocation)
                guard let handle = UUID(uuidString: try arguments.string("handle")) else {
                    throw AgentToolError.invalidArguments("handle is not a valid handle.")
                }
                let outcome = try await background.wait(
                    handle,
                    timeout: .seconds(arguments.optionalInt("timeout_seconds") ?? 60),
                    reporting: reporting(invocation, context.report),
                    // Waiting is all this call does, so there is nothing to lose
                    // by stopping: the command runs on, its session stays, and
                    // the handle is still good. That is what makes a long
                    // `timeout_seconds` safe to ask for.
                    orWhen: context.whenUserInterjects
                )
                guard let exitCode = outcome.exitCode else {
                    return result(invocation, .object([
                        "status": .string("running"),
                        "handle": .string(handle.uuidString),
                        "stdout": .string(outcome.standardOut),
                        "stderr": .string(outcome.standardError),
                    ]))
                }
                return result(invocation, .object([
                    "status": .string("exited"),
                    "stdout": .string(outcome.standardOut),
                    "stderr": .string(outcome.standardError),
                    "exit_code": .number(Double(exitCode)),
                    "signal": outcome.signal.map(AgentJSONValue.string) ?? .null,
                ]))
            }
        )
    }

    static func sshExec(
        _ authentication: AgentSSHAuthenticationRegistry, _ pool: AgentConnectionPool,
        _ background: AgentBackgroundCommands
    ) -> AnyAgentTool {
        let tool = descriptor(
            "ssh_exec", "Execute one command over a dedicated non-PTY SSH exec channel.",
            properties: [
                "host_id": string(), "command": string(max: 32_768), "cwd": string(max: 4_096),
                "timeout_seconds": integer(min: 1, max: 900), "stdin": string(max: 131_072),
                "secret_handle": string(), "stdin_purpose": string(max: 256),
            ], required: ["host_id", "command"], target: .host, safety: .requiresAuthorization,
            presentation: .init(
                symbol: "terminal",
                activity: .semanticArgument(key: "command", fallback: .sshCommand),
                output: .streams,
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
                    "proposed": "Preparing to run “{activity}” on {target}",
                    "waitingForApproval": "Waiting to run “{activity}” on {target}",
                    "waitingForUser": "Waiting to authenticate with {target}",
                    "running": "Connecting to {target}",
                    "command": "Running “{activity}” on {target}",
                    "completed": "Ran “{activity}” on {target}",
                    "denied": "Did not run “{activity}” on {target}",
                    "failed": "Failed to run “{activity}” on {target}",
                    "interrupted": "Stopped waiting for “{activity}” on {target}",
                ]
            )
        )
        return AnyAgentTool(
            descriptor: tool,
            preflight: { invocation in
                var checked = invocation
                let arguments = try Arguments(invocation)
                checked.targetHostID = try arguments.uuid("host_id")
                let command = try arguments.string("command")
                if arguments.optionalString("stdin") != nil && arguments.optionalString("secret_handle") != nil {
                    throw AgentToolError.invalidArguments("stdin and secret_handle are mutually exclusive.")
                }
                let assessment = CommandRiskClassifier.assess(command)
                let safe = assessment.risk == .safe
                return AgentToolPreflight(
                    invocation: checked,
                    safety: safe ? .locallyReadOnly : .requiresAuthorization,
                    reasons: assessment.reasons,
                    // Whether a command may run beside another is a property of
                    // the command, not of `ssh_exec`, and it is decided by the
                    // same locally-proven evidence that just decided `safety`.
                    // A command the classifier cannot vouch for makes its whole
                    // turn serial, so nothing observes the host while it is
                    // being changed.
                    //
                    // The ceiling on what this buys is worth stating: commands
                    // aimed at one host queue behind each other inside
                    // `SSHExecSession` regardless, because a libssh2 session
                    // cannot be driven from two places at once. The win is
                    // several hosts at once, and host work overlapping `fetch`,
                    // `web_search`, and MCP.
                    concurrency: safe ? .parallel : .sequential
                )
            },
            execute: { invocation, context in
                let arguments = try Arguments(invocation)
                let hostID = try arguments.uuid("host_id")
                let command = try arguments.string("command")
                var input = arguments.optionalString("stdin").map { Data($0.utf8) }
                if let rawHandle = arguments.optionalString("secret_handle") {
                    guard let handleID = UUID(uuidString: rawHandle) else {
                        throw AgentToolError.invalidArguments("secret_handle is invalid.")
                    }
                    let purpose = try arguments.string("stdin_purpose")
                    let secret = try await context.secretBroker.consume(
                        SecretHandle(id: handleID),
                        matching: SecretBinding(
                            runID: context.runID, toolName: "ssh_exec", hostID: hostID,
                            purpose: purpose
                        )
                    )
                    input = Data(secret.utf8)
                }
                // Live output, so a command that takes a minute is a card
                // filling in rather than a spinner. Reported, never returned:
                // the model is owed one result per call and gets it below.
                let stream = AgentCommandOutputStream(
                    report: reporting(invocation, context.report)
                )
                let cwd = arguments.optionalString("cwd")
                // A `let` copy, because the task below outlives this call and a
                // captured `var` would be shared mutable state across it.
                let stdin = input
                let deadline = Duration.seconds(
                    arguments.optionalInt("timeout_seconds") ?? defaultReportingDeadline
                )
                // Connecting is inside the deadline too. A hang is a hang
                // whether it is DNS, a jump host or a handshake, and a turn that
                // ends on time is what lets the user be heard at all.
                let handover = AgentCommandHandover()
                let running = Task { () async throws -> SSHExecResult in
                    var connection = try await authentication.execConnection(
                        hostID: hostID, invocationID: invocation.id,
                        interaction: context.userInteraction, pool: pool
                    )
                    var retriedDeadSession = false
                    while true {
                        let session = connection.client
                        // The call may already have given up while this was
                        // connecting. Starting anyway would leave a command
                        // running, printing and finishing with nobody holding
                        // a handle to it.
                        guard retriedDeadSession || handover.beginRunning(on: session) else {
                            throw AgentCommandNotStarted()
                        }
                        context.report(AgentToolResult(
                            callID: invocation.call.id, content: "",
                            metadata: ["presentation_phase": .string("command")]
                        ))
                        do {
                            return try await session.execute(
                                command, workingDirectory: cwd, stdin: stdin,
                                timeout: maximumCommandLifetime,
                                outputLimit: 256 * 1_024,
                                onOutput: stream.handler
                            )
                        } catch SSHExecSessionError.channelUnavailable
                            where !retriedDeadSession
                        {
                            // Safe because no command channel opened. The
                            // authentication actor returned with the connection
                            // keeps one-use credentials for this retry, while its
                            // shared registry lease already ended.
                            retriedDeadSession = true
                            context.report(AgentToolResult(
                                callID: invocation.call.id, content: "",
                                metadata: ["presentation_phase": .string("running")]
                            ))
                            await pool.disconnect(hostID: hostID, kind: .exec)
                            connection.client = try await authentication.openExec(
                                hostID: hostID, authentication: connection.authentication,
                                pool: pool
                            )
                        }
                    }
                }

                guard await AgentBackgroundCommands.settled(running, within: deadline) else {
                    guard let session = handover.giveUp() else {
                        // Still connecting, so there is nothing to hand over —
                        // no session, no output, no handle worth giving. The
                        // connection is left to finish into the pool rather than
                        // torn down, so the retry this invites is the fast one.
                        return result(invocation, .object([
                            "status": .string("connecting"),
                            "note": .string(String(
                                localized: """
                                    The host has not finished answering after \
                                    \(deadline.components.seconds)s, so the command has not \
                                    started. Nothing ran. The connection is still being set up; \
                                    running this again shortly is likely to be quick.
                                    """
                            )),
                        ]), truncated: false)
                    }
                    // It outlived its turn. The session goes with it — the
                    // channel is still being pumped, so it can be neither shared
                    // nor swept — and the next command for this host opens a
                    // fresh one.
                    await pool.detachExec(hostID: hostID, session: session)
                    let handle = await background.adopt(
                        hostID: hostID, command: command, stream: stream,
                        task: running, session: session
                    )
                    let captured = stream.captured
                    return result(invocation, .object([
                        "status": .string("running"),
                        "handle": .string(handle.uuidString),
                        "stdout": .string(captured.standardOut),
                        "stderr": .string(captured.standardError),
                        "note": .string(String(
                            localized: """
                                Still running after \(deadline.components.seconds)s. The output \
                                above is what it has printed so far. Call ssh_wait with this \
                                handle for the rest; leaving it unasked-about abandons it.
                                """
                        )),
                    ]))
                }
                return exitedResult(invocation, try await running.value)
            }
        )
    }

    static func terminalSuggest() -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "terminal_suggest", "Create a command card. Only the user can insert or run it in a PTY.",
            properties: ["command": string(max: 32_768), "explanation": string(max: 4_096)],
            required: ["command"], target: .user, safety: .locallyReadOnly,
            // It writes a card and touches nothing else. Whatever the command
            // would do if the user ran it is the user's action, later.
            concurrency: .parallel,
            presentation: .init(
                symbol: "terminal", activity: .semanticArgument(key: "command", fallback: .command),
                groupsWithAdjacentTools: false,
                actionKind: .suggest
            )
        )) { invocation, _ in
            let arguments = try Arguments(invocation)
            let command = try arguments.string("command")
            guard !command.contains("\n"), !command.contains("\r"), !command.contains("\0") else {
                throw AgentToolError.invalidArguments("A terminal suggestion must be one command line.")
            }
            return result(invocation, .object([
                "command": .string(command),
                "explanation": .string(arguments.optionalString("explanation") ?? ""),
                "risk": .string(CommandRiskClassifier.assess(command).risk.label),
                "requires_user_action": .bool(true),
            ]))
        }
    }
}
