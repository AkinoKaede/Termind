import AgentKit
import Foundation
import TermindApplication
import TermindDomain

nonisolated public struct ListHostsTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.list_hosts", present: present
    )
    public let hosts: AgentHostResolver

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "list_hosts",
            """
            List Vault and temporary Termind SSH targets without credentials. Use this to discover host IDs \
            when no session context is attached, including in the standalone Assistant outside the sidebar. \
            Pass a returned host's id as host_id to SSH or SFTP tools; no active terminal session is required.
            """,
            properties: [:], required: [], target: .host, approvalPolicy: .approve,
            concurrency: .parallel,
            presentation: .init(
                symbol: "server.rack", activity: .semanticLabel(.hosts), output: .json,
                actionKind: .list
            )
        )
    }

    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let listing = await hosts.listing()
        let rows = listing.hosts.map { target in
            AgentJSONValue.object([
                "id": .string(target.id.uuidString), "display_name": .string(target.displayName),
                "address": .string(target.address), "tags": .array(target.tags.map(AgentJSONValue.string)),
                "connection_state": .string(target.connectionState), "temporary": .bool(target.isTemporary),
                "group_id": target.groupID.map { .string($0.uuidString) } ?? .null,
                "group_path": target.groupPath.map(AgentJSONValue.string) ?? .null,
            ])
        }
        func groupJSON(_ group: AgentHostGroupTarget) -> AgentJSONValue {
            .object([
                "id": .string(group.id.uuidString), "name": .string(group.name),
                "path": .string(group.path), "children": .array(group.children.map(groupJSON)),
            ])
        }
        return Self.result(
            invocation,
            .object([
                "groups": .array(listing.groups.map(groupJSON)), "hosts": .array(rows),
            ]))
    }

    public init(hosts: AgentHostResolver) {
        self.hosts = hosts
    }
}

nonisolated public struct SSHWaitTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.ssh_wait", present: present
    )
    public let background: AgentBackgroundCommands

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "ssh_wait", "Wait for a command ssh_exec reported as still running, and return its output.",
            properties: [
                "handle": Self.string(max: 64),
                "timeout_seconds": Self.integer(min: 1, max: 900),
            ],
            required: ["handle"], target: .host, approvalPolicy: .approve,
            concurrency: .parallel,
            presentation: .init(
                symbol: "clock.arrow.circlepath", activity: .semanticLabel(.remoteCommand),
                output: .streams, actionKind: .wait
            )
        )
    }

    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let arguments = try Arguments(invocation)
        guard let handle = UUID(uuidString: try arguments.string("handle")) else {
            throw AgentToolError.invalidArguments("handle is not a valid handle.")
        }
        let outcome = try await background.wait(
            handle, timeout: .seconds(arguments.optionalInt("timeout_seconds") ?? 60),
            reporting: AgentToolSupport.reporting(invocation, context.report),
            orWhen: context.whenUserInterjects
        )
        guard let exitCode = outcome.exitCode else {
            return Self.result(
                invocation,
                .object([
                    "status": .string("running"), "handle": .string(handle.uuidString),
                    "stdout": .string(outcome.standardOut), "stderr": .string(outcome.standardError),
                ]))
        }
        return Self.result(
            invocation,
            .object([
                "status": .string("exited"), "stdout": .string(outcome.standardOut),
                "stderr": .string(outcome.standardError), "exit_code": .number(Double(exitCode)),
                "signal": outcome.signal.map(AgentJSONValue.string) ?? .null,
            ]))
    }

    public init(background: AgentBackgroundCommands) {
        self.background = background
    }
}

nonisolated public struct TerminalSuggestTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.terminal_suggest", present: present
    )
    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "terminal_suggest",
            """
            Create a command card when the user wants a suggestion or needs to interact with a PTY. \
            Only the user can insert or run the card. This tool does not execute commands or return \
            execution output. To run a remote command yourself, use ssh_exec.
            """,
            properties: [
                "command": Self.string(max: 32_768),
                "explanation": Self.string(max: 4_096),
            ],
            required: ["command"], target: .user, approvalPolicy: .approve,
            concurrency: .parallel,
            presentation: .init(
                symbol: "terminal", activity: .semanticArgument(key: "command", fallback: .command),
                groupsWithAdjacentTools: false, actionKind: .suggest
            )
        )
    }
    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let arguments = try Arguments(invocation)
        let command = try arguments.string("command")
        guard !command.contains("\n"), !command.contains("\r"), !command.contains("\0") else {
            throw AgentToolError.invalidArguments("A terminal suggestion must be one command line.")
        }
        return Self.result(
            invocation,
            .object([
                "command": .string(command),
                "explanation": .string(arguments.optionalString("explanation") ?? ""),
                "risk": .string(CommandRiskClassifier.assess(command).risk.label),
                "requires_user_action": .bool(true),
            ]))
    }
}

nonisolated extension SSHWaitTool {
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        SSHCommandPresentation.present(input)
    }
}

nonisolated extension TerminalSuggestTool {
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        let object = input.result.objectValue ?? [:]
        let command =
            input.arguments["command"]?.stringValue
            ?? object["command"]?.stringValue ?? ""
        var items: [AgentToolDetail.Item] = [F.text("Command", command, locale: input.locale)]
        if let explanation = F.nonempty(
            input.arguments["explanation"]?.stringValue ?? object["explanation"]?.stringValue
        ) {
            items.append(.message(explanation, .secondary))
        }
        let assessment = CommandRiskClassifier.assess(command)
        items.append(F.field("Risk", assessment.risk.label, locale: input.locale))
        items.append(contentsOf: assessment.reasons.map { .message($0, .warning) })
        items.append(.message(F.localized("Requires user action", locale: input.locale), .warning))
        return items
    }
}

nonisolated extension AgentToolSupport {
    /// How long `ssh_exec` waits before telling the model what it has.
    ///
    /// Short, and safe to be short only because expiry stopped being
    /// destructive. It used to throw, discard the session, and lose everything
    /// the command had printed — while the command itself carried on running on
    /// the host — so the default had to be generous enough that it rarely
    /// happened. Now it hands back the output and a handle, which makes a short
    /// deadline pure gain: turns end in seconds, and anything the user typed
    /// while waiting is delivered at the boundary that follows.
    fileprivate static let defaultReportingDeadline = 15

    /// The ceiling on how long a command may run at all, deadline or no. Matches
    /// the clamp the session's own pump applies.
    fileprivate static let maximumCommandLifetime: TimeInterval = 15 * 60

    /// The sink that turns captured output into progress on this call's card.
    fileprivate static func reporting(
        _ invocation: AgentToolInvocation,
        _ report: @escaping @Sendable (AgentToolResult) -> Void
    ) -> @Sendable (String, String) -> Void {
        { out, error in
            var progress = result(
                invocation,
                .object([
                    "status": .string("running"),
                    "stdout": .string(out), "stderr": .string(error),
                ]))
            progress.metadata["presentation_phase"] = .string("command")
            report(progress)
        }
    }

    fileprivate static func exitedResult(
        _ invocation: AgentToolInvocation, _ output: SSHExecResult
    ) -> AgentToolResult {
        result(
            invocation,
            .object([
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
}

nonisolated public struct SSHExecTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.ssh_exec", present: present,
        presentArguments: presentArguments
    )
    public let authentication: AgentSSHAuthenticationRegistry
    public let pool: AgentConnectionPool
    public let background: AgentBackgroundCommands

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "ssh_exec",
            """
            Execute a remote command and return its output over a dedicated non-PTY SSH exec channel. \
            Use this to run commands or inspect a host, even without an open interactive terminal or \
            attached session context. When context is absent, discover host_id with list_hosts. \
            Only host_id and command are required. Termind handles SSH login using the host configuration \
            and prompts for authentication when needed; do not call request_user_secret for SSH login. \
            Use a secret handle only when the command actually needs secret standard input.
            """,
            properties: [
                "host_id": Self.described(
                    Self.string(),
                    "The intended host's ID from session context or list_hosts."
                ),
                "command": Self.described(
                    Self.string(max: 32_768), "The remote command to execute. Never include plaintext secrets."
                ),
                "cwd": Self.string(max: 4_096),
                "timeout_seconds": Self.integer(min: 1, max: 900),
                "stdin": Self.described(
                    Self.string(max: 131_072),
                    "Optional non-secret standard input. Mutually exclusive with secret_handle."
                ),
                "secret_handle": Self.described(
                    Self.string(),
                    """
                    Optional one-shot handle returned by request_user_secret for this run, host and ssh_exec. \
                    Supplies secret standard input to the command, not SSH login credentials. Omit when no \
                    secret input is needed; never invent a handle. Mutually exclusive with stdin.
                    """
                ),
                "stdin_purpose": Self.described(
                    Self.string(max: 256),
                    "Required with secret_handle: exactly the purpose used in request_user_secret. Omit otherwise."
                ),
            ], required: ["host_id", "command"], target: .host, approvalPolicy: .ask,
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
    }

    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
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
            approvalPolicy: safe ? .approve : .ask,
            reasons: assessment.reasons,
            // Whether a command may run beside another is a property of
            // the command, not of `ssh_exec`, and it is decided by the
            // same locally-proven evidence that just decided `approvalPolicy`.
            // A command the classifier cannot vouch for makes its whole
            // turn serial, so nothing observes the host while it is
            // being changed.
            //
            // Safe commands may overlap even when aimed at one host:
            // `SSHExecSession` gives each command its own Channel on the
            // shared transport, while one fair owner serializes the actual
            // libssh2 calls. Commands on separate hosts can also run at once,
            // as can host work alongside `fetch`, `web_search`, and MCP.
            concurrency: safe ? .parallel : .sequential
        )
    }

    public func execute(
        _ invocation: AgentToolInvocation, context: AgentToolExecutionContext
    ) async throws -> AgentToolResult {
        let arguments = try Arguments(invocation)
        let hostID = try arguments.uuid("host_id")
        let command = try arguments.string("command")
        var input = arguments.optionalString("stdin").map { Data($0.utf8) }
        if let rawHandle = arguments.optionalString("secret_handle") {
            guard let handleID = UUID(uuidString: rawHandle) else {
                throw AgentToolError.invalidArguments(
                    "secret_handle must be a handle issued by request_user_secret in this "
                        + "run. Omit secret_handle and stdin_purpose when the command needs "
                        + "no secret input; otherwise call request_user_secret again."
                )
            }
            let purpose = try arguments.string("stdin_purpose")
            let secret: String
            do {
                secret = try await context.secretBroker.consume(
                    SecretHandle(id: handleID),
                    matching: SecretBinding(
                        runID: context.runID, toolName: "ssh_exec", hostID: hostID,
                        purpose: purpose
                    )
                )
            } catch SecretBrokerError.notFound {
                throw AgentToolError.invalidArguments(
                    "secret_handle is unavailable or has already been used. Call "
                        + "request_user_secret again before retrying ssh_exec."
                )
            } catch SecretBrokerError.bindingMismatch {
                throw AgentToolError.invalidArguments(
                    "secret_handle was issued for a different run, host, tool, or purpose. "
                        + "Call request_user_secret again with matching values."
                )
            }
            input = Data(secret.utf8)
        }
        // Live output, so a command that takes a minute is a card
        // filling in rather than a spinner. Reported, never returned:
        // the model is owed one result per call and gets it below.
        let stream = AgentCommandOutputStream(
            report: AgentToolSupport.reporting(invocation, context.report)
        )
        let cwd = arguments.optionalString("cwd")
        // A `let` copy, because the task below outlives this call and a
        // captured `var` would be shared mutable state across it.
        let stdin = input
        let deadline = Duration.seconds(
            arguments.optionalInt("timeout_seconds")
                ?? AgentToolSupport.defaultReportingDeadline
        )
        // Connecting is inside the deadline too. A hang is a hang
        // whether it is DNS, a jump host or a handshake, and a turn that
        // ends on time is what lets the user be heard at all.
        let handover = AgentCommandHandover()
        let running = Task { () async throws -> SSHExecResult in
            var connection = try await authentication.execConnection(
                hostID: hostID, invocationID: invocation.id,
                interaction: context.sshInteraction, pool: pool
            )
            var retriedDeadSession = false
            while true {
                let session = connection.client
                // The call may already have given up while this was
                // connecting. Starting anyway would leave a command
                // running, printing and finishing with nobody holding
                // a handle to it.
                guard retriedDeadSession || handover.beginRunning() else {
                    throw AgentCommandNotStarted()
                }
                context.report(
                    AgentToolResult(
                        callID: invocation.call.id, content: "",
                        metadata: ["presentation_phase": .string("command")]
                    ))
                do {
                    return try await pool.withExecLease(hostID: hostID, session: session) {
                        try await session.execute(
                            command, workingDirectory: cwd, stdin: stdin,
                            timeout: AgentToolSupport.maximumCommandLifetime,
                            outputLimit: 256 * 1_024,
                            onOutput: stream.handler)
                    }
                } catch SSHExecSessionError.transportUnavailable
                    where !retriedDeadSession
                {
                    // Safe because no command channel opened. The
                    // authentication actor returned with the connection
                    // keeps one-use credentials for this retry, while its
                    // shared registry lease already ended.
                    retriedDeadSession = true
                    context.report(
                        AgentToolResult(
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
            guard handover.giveUp() else {
                // Still connecting, so there is nothing to hand over —
                // no session, no output, no handle worth giving. The
                // connection is left to finish into the pool rather than
                // torn down, so the retry this invites is the fast one.
                return Self.result(
                    invocation,
                    .object([
                        "status": .string("connecting"),
                        "note": .string(
                            String(
                                localized: """
                                    The host has not finished answering after \
                                    \(deadline.components.seconds)s, so the command has not \
                                    started. Nothing ran. The connection is still being set up; \
                                    running this again shortly is likely to be quick.
                                    """
                            )),
                    ]), truncated: false)
            }
            // It outlived its turn. Only this command's Channel goes with the
            // background handle; the transport remains available to peers.
            let handle = await background.adopt(
                stream: stream, task: running
            )
            let captured = stream.captured
            return Self.result(
                invocation,
                .object([
                    "status": .string("running"),
                    "handle": .string(handle.uuidString),
                    "stdout": .string(captured.standardOut),
                    "stderr": .string(captured.standardError),
                    "note": .string(
                        String(
                            localized: """
                                Still running after \(deadline.components.seconds)s. The output \
                                above is what it has printed so far. Call ssh_wait with this \
                                handle for the rest; leaving it unasked-about abandons it.
                                """
                        )),
                ]))
        }
        return AgentToolSupport.exitedResult(invocation, try await running.value)
    }

    public init(
        authentication: AgentSSHAuthenticationRegistry, pool: AgentConnectionPool, background: AgentBackgroundCommands
    ) {
        self.authentication = authentication
        self.pool = pool
        self.background = background
    }
}

nonisolated extension SSHExecTool {
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        SSHCommandPresentation.present(input)
    }

    public static func presentArguments(
        _ input: AgentToolArgumentDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        var items: [AgentToolDetail.Item] = []
        if let command = input.arguments["command"]?.stringValue {
            items.append(F.text("Command", command, locale: input.locale))
        }
        F.appendField(
            &items, "Working directory", input.arguments["cwd"]?.stringValue,
            locale: input.locale, monospaced: true)
        if let seconds = input.arguments["timeout_seconds"]?.integerValue {
            items.append(
                F.field("Timeout", "\(seconds)s", locale: input.locale, monospaced: true))
        }
        if let standardInput = input.arguments["stdin"]?.stringValue {
            items.append(F.text("Input", standardInput, locale: input.locale))
        }
        F.appendField(
            &items, "Secret handle", input.arguments["secret_handle"]?.stringValue,
            locale: input.locale, monospaced: true)
        F.appendField(
            &items, "Purpose", input.arguments["stdin_purpose"]?.stringValue,
            locale: input.locale)
        return items
    }
}

nonisolated public enum SSHCommandPresentation {
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            if let status = object["status"]?.stringValue {
                items.append(
                    F.field(
                        "Status", F.statusLabel(status, locale: input.locale), locale: input.locale
                    ))
            }
            if let code = object["exit_code"]?.integerValue {
                items.append(F.field("Exit code", String(code), locale: input.locale, monospaced: true))
            }
            F.appendField(
                &items, "Signal", object["signal"]?.stringValue,
                locale: input.locale, monospaced: true)
            let stdout = object["stdout"]?.stringValue ?? ""
            let stderr = object["stderr"]?.stringValue ?? ""
            if !stdout.isEmpty { items.append(F.text("Standard output", stdout, locale: input.locale)) }
            if !stderr.isEmpty { items.append(F.text("Standard error", stderr, locale: input.locale)) }
            if stdout.isEmpty, stderr.isEmpty, object["note"] == nil {
                items.append(.message(F.localized("No output", locale: input.locale), .secondary))
            }
            if let note = F.nonempty(object["note"]?.stringValue) {
                items.append(.message(note, .warning))
            }
            return items
        }
    }
}

// MARK: - Tool-owned transcript details

nonisolated extension ListHostsTool {

    private struct HostGroupDetailProjection {
        let id: String
        let title: String
    }

    public static func present(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        return F.objectItems(input) { object in
            let hostValues = object["hosts"]?.arrayValue ?? []
            let groupValues = object["groups"]?.arrayValue ?? []
            var groups: [HostGroupDetailProjection] = []

            func walk(_ rows: [AgentJSONValue], prefix: String = "") {
                for row in rows {
                    guard let fields = row.objectValue else { continue }
                    let name =
                        F.nonempty(fields["name"]?.stringValue)
                        ?? F.localized("Unnamed group", locale: input.locale)
                    let computed = prefix.isEmpty ? name : "\(prefix) / \(name)"
                    let title = F.nonempty(fields["path"]?.stringValue) ?? computed
                    if let id = fields["id"]?.stringValue {
                        groups.append(.init(id: id, title: title))
                    }
                    walk(fields["children"]?.arrayValue ?? [], prefix: computed)
                }
            }
            walk(groupValues)

            var grouped: [String: [AgentToolDetail.ListRow]] = [:]
            var ungrouped: [AgentToolDetail.ListRow] = []
            var temporary: [AgentToolDetail.ListRow] = []
            var connected = 0
            for hostValue in hostValues {
                guard let host = hostValue.objectValue else { continue }
                if host["connection_state"]?.stringValue == "connected" { connected += 1 }
                let row = hostDetailRow(host, locale: input.locale)
                if host["temporary"]?.boolValue == true {
                    temporary.append(row)
                } else if let groupID = host["group_id"]?.stringValue,
                    groups.contains(where: { $0.id == groupID })
                {
                    grouped[groupID, default: []].append(row)
                } else {
                    ungrouped.append(row)
                }
            }

            guard !hostValues.isEmpty || !groups.isEmpty else {
                return [.message(F.localized("No hosts available", locale: input.locale), .secondary)]
            }
            func hostCount(_ count: Int) -> String {
                String(localized: "\(count) hosts", locale: input.locale)
            }
            var summary = [hostCount(hostValues.count)]
            if connected > 0 {
                summary.append(String(localized: "\(connected) connected", locale: input.locale))
            }
            if !temporary.isEmpty {
                summary.append(String(localized: "\(temporary.count) temporary", locale: input.locale))
            }
            var sections = groups.map { group in
                let rows = grouped[group.id] ?? []
                return AgentToolDetail.ListSection(
                    title: "\(group.title) · \(hostCount(rows.count))", rows: rows
                )
            }
            if !groups.isEmpty || !ungrouped.isEmpty {
                sections.append(
                    .init(
                        title: "\(F.localized("Ungrouped", locale: input.locale)) · \(hostCount(ungrouped.count))",
                        rows: ungrouped
                    ))
            }
            if !temporary.isEmpty {
                sections.append(
                    .init(
                        title: "\(F.localized("Temporary", locale: input.locale)) · \(hostCount(temporary.count))",
                        rows: temporary
                    ))
            }
            return [
                .groupedList(
                    .init(
                        summary: summary.joined(separator: " · "), sections: sections,
                        isScrollable: hostValues.count > 12
                    ))
            ]
        }
    }

    private static func hostDetailRow(
        _ host: [String: AgentJSONValue], locale: Locale
    ) -> AgentToolDetail.ListRow {
        typealias F = AgentToolDetailFormatting
        let address = F.nonempty(host["address"]?.stringValue)
        let name =
            F.nonempty(host["display_name"]?.stringValue) ?? address
            ?? F.localized("Unnamed host", locale: locale)
        let state = connectionDetailState(host["connection_state"]?.stringValue ?? "", locale: locale)
        let subtitle = [address ?? F.localized("Address unavailable", locale: locale), state.label]
            .joined(separator: " · ")
        let tags = host["tags"]?.arrayValue?.compactMap { F.nonempty($0.stringValue) } ?? []
        return .init(
            title: name, subtitle: subtitle, badges: tags, symbol: "circle.fill", tint: state.tint
        )
    }

    private static func connectionDetailState(
        _ raw: String, locale: Locale
    ) -> (label: String, tint: AgentToolDetail.Tint) {
        typealias F = AgentToolDetailFormatting
        return switch raw {
        case "connected": (F.localized("Connected", locale: locale), AgentToolDetail.Tint.success)
        case "connecting": (F.localized("Connecting", locale: locale), AgentToolDetail.Tint.warning)
        case "reconnecting": (F.localized("Reconnecting", locale: locale), AgentToolDetail.Tint.warning)
        case "disconnected": (F.localized("Not connected", locale: locale), AgentToolDetail.Tint.secondary)
        case "failed": (F.localized("Failed", locale: locale), AgentToolDetail.Tint.failure)
        default:
            (
                F.nonempty(F.humanized(raw))?.capitalized
                    ?? F.localized("Unknown", locale: locale),
                AgentToolDetail.Tint.secondary
            )
        }
    }

}
