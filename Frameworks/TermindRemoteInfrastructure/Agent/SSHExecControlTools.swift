import AgentKit
import Foundation
import TermindApplication
import TermindDomain

nonisolated enum SSHExecResults: AgentToolSchemaBuilding {
    static func snapshot(_ invocation: AgentToolInvocation, _ value: AgentJSONValue) -> AgentToolResult {
        var fields = value.objectValue ?? [:]
        let capture = fields.removeValue(forKey: "output_capture").flatMap(AgentOutputCaptureInfo.init(json:))
        let id = fields.removeValue(forKey: "output_capture_id")
        let revision = fields.removeValue(forKey: "output_revision")
        let totalLines = fields.removeValue(forKey: "output_total_lines")
        let lineOffset = fields.removeValue(forKey: "output_line_offset")
        let truncated = fields.removeValue(forKey: "output_truncated")?.boolValue ?? false
        var result = result(invocation, .object(fields), truncated: truncated)
        result.isError = fields["status"]?.stringValue == "failed"
        result.outputCapture = capture
        result.metadata["output_capture_id"] = id
        result.metadata["output_revision"] = revision
        result.metadata["output_total_lines"] = totalLines
        result.metadata["output_line_offset"] = lineOffset
        return result
    }

    static func handle(_ invocation: AgentToolInvocation) throws -> UUID {
        guard let raw = try Arguments(invocation).optionalString("handle"), let handle = UUID(uuidString: raw) else {
            throw AgentToolError.invalidArguments("handle must be a UUID returned by ssh_exec_run.")
        }
        return handle
    }

    static func handleArguments(_ input: AgentToolArgumentDetailInput) -> [AgentToolDetail.Item] {
        guard let handle = input.arguments["handle"]?.stringValue else { return [] }
        return [AgentToolDetailFormatting.field("Handle", handle, locale: input.locale, monospaced: true)]
    }
}

nonisolated public struct SSHExecOutputTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.ssh_exec_output",
        layout: .init(singleLineHeader: true, boundsApprovalHeight: true, truncateStrategy: .tail),
        present: { AgentToolDetailFormatting.genericItems($0.result, locale: $0.locale) },
        presentArguments: SSHExecResults.handleArguments)
    public let background: AgentBackgroundCommands
    public let scope: UUID
    public var truncateStrategy: AgentTruncateStrategy { .tail }

    public init(background: AgentBackgroundCommands, scope: UUID) {
        self.background = background
        self.scope = scope
    }

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "ssh_exec_output",
            "Return the current cumulative ssh_exec_run snapshot immediately. Reads do not consume output or extend retention. No waiting or timeout. Combined output uses complete-line tail selection at 64 KiB / 2000 lines; truncation notices include the generated scratch path for scratch_read or scratch_search.",
            properties: ["handle": Self.string(max: 64)], required: ["handle"],
            target: .host, approvalPolicy: .approve, concurrency: .parallel,
            presentation: .init(
                symbol: "text.alignleft", activity: .semanticLabel(.commandOutput),
                output: .streams, actionKind: .read))
    }

    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        SSHExecResults.snapshot(
            invocation,
            try await background.output(SSHExecResults.handle(invocation), scope: scope) {
                "\(scope.uuidString.lowercased())/outputs/ssh-exec-output-\(UUID().uuidString.lowercased()).txt"
            })
    }
}

nonisolated public struct SSHExecStdinTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.ssh_exec_stdin",
        present: { AgentToolDetailFormatting.genericItems($0.result, locale: $0.locale) },
        presentArguments: presentArguments)
    public let background: AgentBackgroundCommands
    public let scope: UUID
    private let planning: Bool

    public init(background: AgentBackgroundCommands, scope: UUID, planning: Bool = false) {
        self.background = background
        self.scope = scope
        self.planning = planning
    }

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "ssh_exec_stdin",
            """
            Write to the stdin of the existing background command identified by handle, on that command's host. \
            type=text requires stdin (empty is a zero-byte write); \
            type=secret consumes a one-shot secret_handle from request_user_secret and delivers the user's \
            securely entered bytes directly to that command's stdin. The opaque secret_handle is not the \
            secret itself. Plaintext is intentionally absent from arguments, review context and results; \
            this tool does not retrieve saved SSH credentials. Use secret input for the command and purpose \
            the user authorized, such as answering its password prompt. Name the host, receiving command and \
            intended use in the secure-input prompt. If existing user instructions do not cover that use and \
            destination, obtain explicit user confirmation before requesting the secret; use request_user_input \
            when available so the answer is visible to review. \
            For review, assess the receiving command, destination and authorized use, not the hidden secret's \
            literal value. Missing plaintext alone does not imply exfiltration. A handle is not blanket \
            authorization: commands that echo, log, store or forward the secret need separate consideration. \
            type=eof accepts neither payload and closes stdin after queued writes. \
            Omit unused payload fields or set them to null. No automatic newline: send \
            an explicit text newline if needed. Repeated EOF is harmless, writes after EOF fail. \
            Returns handle, status (written/closed), bytes_written and stdin_closed. bytes_written counts \
            encoded bytes handed to SSH, not confirmed remote consumption. Never blindly retry a failed write.
            """,
            properties: [
                "handle": Self.string(max: 64), "type": Self.enumeration(["text", "secret", "eof"]),
                "stdin": Self.string(max: 131_072), "secret_handle": Self.string(max: 64),
            ], required: ["handle", "type"], target: .host, approvalPolicy: .ask,
            presentation: .init(symbol: "text.cursor", activity: .semanticLabel(.remoteCommand), actionKind: .write))
    }

    private func inputType(_ invocation: AgentToolInvocation) throws -> String {
        let args = try Arguments(invocation)
        let type = try args.string("type")
        // Strict provider schemas represent unused optional payloads as null.
        let payloads = args.object.filter { $0.value != .null }
        let text = payloads["stdin"]
        let secret = payloads["secret_handle"]
        switch type {
        case "text" where text?.stringValue != nil && secret == nil: break
        case "secret" where text == nil && secret?.stringValue.flatMap(UUID.init(uuidString:)) != nil: break
        case "eof" where text == nil && secret == nil: break
        default:
            throw AgentToolError.invalidArguments(
                "Supply only stdin for text, only secret_handle for secret, or neither for eof.")
        }
        return type
    }

    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        let type = try inputType(invocation)
        let command = try await background.command(SSHExecResults.handle(invocation), scope: scope)
        var checked = invocation
        checked.targetHostID = command.hostID
        let denied = planning && CommandRiskClassifier.assess(command.command).risk == .destructive
        var reasons = [
            denied ? "Planning cannot continue a destructive SSH command." : "Write input to: \(command.command)"
        ]
        if type == "secret" {
            reasons.append(
                "Consume a one-shot secret handle locally and deliver its bytes only to this command's stdin. "
                    + "The plaintext is intentionally hidden from review; authorization must cover the receiving command, "
                    + "host and use. The command may still echo, store or forward those bytes.")
        }
        return .init(
            invocation: checked, approvalPolicy: denied ? .deny : .ask, reasons: reasons, concurrency: .sequential)
    }

    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let type = try inputType(invocation)
        let handle = try SSHExecResults.handle(invocation)
        _ = try await background.command(handle, scope: scope)
        let args = try Arguments(invocation)
        let input: SSHCommandInput?
        switch type {
        case "text": input = .text(args.optionalString("stdin")!)
        case "secret":
            let secret = try await context.secretBroker.consume(
                SecretHandle(id: try args.uuid("secret_handle")))
            defer { secret.clear() }
            return Self.result(invocation, try await background.write(handle, scope: scope, input: .secret(secret)))
        default: input = nil
        }
        return Self.result(invocation, try await background.write(handle, scope: scope, input: input))
    }

    public static func presentArguments(_ input: AgentToolArgumentDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        var items = SSHExecResults.handleArguments(input)
        if let type = input.arguments["type"]?.stringValue {
            items.append(
                F.field(
                    "Input", type == "secret" ? F.localized("Secret", locale: input.locale) : type,
                    locale: input.locale))
        }
        if input.arguments["type"]?.stringValue == "text", let text = input.arguments["stdin"]?.stringValue {
            items.append(F.text("Input", text, locale: input.locale))
        }
        return items
    }

}

nonisolated public struct PlanningSSHExecStdinTool: AgentToolDefinition {
    public static let presenter = SSHExecStdinTool.presenter
    private let base: SSHExecStdinTool
    public init(background: AgentBackgroundCommands, scope: UUID) {
        base = SSHExecStdinTool(background: background, scope: scope, planning: true)
    }
    public var descriptor: AgentToolDescriptor { base.descriptor }
    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        try await base.preflight(invocation)
    }
    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        try await base.execute(invocation, context: context)
    }
}

nonisolated public struct SSHExecCancelTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.ssh_exec_cancel",
        present: { AgentToolDetailFormatting.genericItems($0.result, locale: $0.locale) },
        presentArguments: SSHExecResults.handleArguments)
    public let background: AgentBackgroundCommands
    public let scope: UUID
    public init(background: AgentBackgroundCommands, scope: UUID) {
        self.background = background
        self.scope = scope
    }
    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "ssh_exec_cancel",
            """
            Cancel the local command task and retire its handle, or release a finished result. \
            Does not send TERM/KILL and does not confirm remote termination. Read output before cancelling. \
            Returns handle, status (cancelled/released), was_running and remote_termination_confirmed=false.
            """,
            properties: ["handle": Self.string(max: 64)], required: ["handle"], target: .host,
            approvalPolicy: .approve,
            presentation: .init(symbol: "stop.circle", activity: .semanticLabel(.remoteCommand), actionKind: .cancel))
    }
    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        Self.result(invocation, try await background.cancel(SSHExecResults.handle(invocation), scope: scope))
    }
}

nonisolated public struct SSHExecListTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.ssh_exec_list",
        present: { AgentToolDetailFormatting.genericItems($0.result, locale: $0.locale) })
    public let background: AgentBackgroundCommands
    public let scope: UUID
    public init(background: AgentBackgroundCommands, scope: UUID) {
        self.background = background
        self.scope = scope
    }
    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "ssh_exec_list",
            """
            List this conversation/session's confirmed commands, newest first. Optional host_id filters by host; \
            include_finished defaults to false. Returns commands with handle, host_id, command, status, stdin_closed, \
            started_at, finished_at, exit_code, signal and error, but no input/output bodies.
            """,
            properties: ["host_id": Self.string(max: 64), "include_finished": Self.boolean()], required: [],
            target: .host, approvalPolicy: .approve, concurrency: .parallel,
            presentation: .init(
                symbol: "list.bullet.rectangle", activity: .semanticLabel(.remoteCommand), actionKind: .list))
    }
    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let args = try Arguments(invocation)
        let hostID = try args.optionalString("host_id").map { _ in try args.uuid("host_id") }
        return Self.result(
            invocation,
            await background.list(
                scope: scope, hostID: hostID, includeFinished: args.optionalBool("include_finished") ?? false))
    }

}
