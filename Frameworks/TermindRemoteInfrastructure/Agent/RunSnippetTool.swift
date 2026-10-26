// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindDomain

nonisolated public struct RunSnippetTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.run_snippet",
        layout: .init(singleLineHeader: true, boundsApprovalHeight: true, truncateStrategy: .tail),
        present: { AgentToolDetailFormatting.genericItems($0.result, locale: $0.locale) },
        presentArguments: SSHExecRunTool.presentArguments)
    let manager: AgentResourceManager
    let base: SSHExecRunTool
    let planning: Bool
    public var truncateStrategy: AgentTruncateStrategy { base.truncateStrategy }

    public var descriptor: AgentToolDescriptor {
        var value = Self.descriptor(
            TermindToolName.runSnippet,
            """
            Run a saved snippet on one explicit host_id using ssh_exec_run. No terminal is opened and saved \
            target lists are never broadcast to. The approved script is frozen at preflight. Same risk approval, \
            planning restrictions, output, run_in_background behavior and session-scoped handles as ssh_exec_run. \
            Use ssh_exec_output, ssh_exec_stdin and ssh_exec_cancel with the returned handle.
            """,
            properties: [
                "snippet_id": Self.string(max: 36), "host_id": Self.string(max: 36),
                "run_in_background": .object([
                    "anyOf": .array([Self.boolean(), .object(["type": .string("null")])])
                ]),
            ], required: ["snippet_id", "host_id"], target: .host, approvalPolicy: .ask,
            presentation: base.descriptor.presentation)
        value.presentation?.activity = .semanticLabel(.snippets)
        return value
    }

    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        let args = try ResourceToolArguments(invocation.call.arguments)
        let command = try await manager.snippetCommand(id: args.uuid("snippet_id"), hostID: args.uuid("host_id"))
        var checked = invocation
        var fields = args.values
        fields["command"] = .string(command)
        checked.call.arguments = .object(fields)
        let policy =
            planning
            ? try await PlanningSSHExecRunTool(
                authentication: base.authentication, pool: base.pool, background: base.background, scope: base.scope
            ).preflight(checked)
            : try await base.preflight(checked)
        return AgentToolPreflight(
            invocation: policy.invocation, approvalPolicy: policy.approvalPolicy, reasons: policy.reasons,
            concurrency: policy.concurrency,
            executionMetadata: ["snippet_command": .string(command)])
    }

    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        guard let command = context.preflightMetadata["snippet_command"]?.stringValue else {
            throw ResourceToolError.invalidInput
        }
        var checked = invocation
        var fields = invocation.call.arguments.objectValue ?? [:]
        fields["command"] = .string(command)
        checked.call.arguments = .object(fields)
        return try await base.execute(checked, context: context)
    }
}
