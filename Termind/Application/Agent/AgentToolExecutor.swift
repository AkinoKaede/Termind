import Foundation

/// One tool call that has been checked and is ready to run — or that already
/// failed before it could.
///
/// Planning is separated from execution because the batch cannot be scheduled
/// until every call in it has been preflighted: whether `ssh_exec` may run
/// beside anything else is decided by `CommandRiskClassifier` during preflight,
/// so the concurrency of the batch is not known until then.
nonisolated enum AgentPlannedToolCall: Sendable {
    case ready(Ready)
    case rejected(invocation: AgentToolInvocation, result: AgentToolResult)

    nonisolated struct Ready: Sendable {
        var tool: AnyAgentTool
        var invocation: AgentToolInvocation
        /// Post-preflight, so this is the descriptor the approval gate, the
        /// card, and the hooks all see.
        var descriptor: AgentToolDescriptor
        var reasons: [String]
        var executionMetadata: [String: AgentJSONValue]
    }

    var invocation: AgentToolInvocation {
        switch self {
        case .ready(let ready): ready.invocation
        case .rejected(let invocation, _): invocation
        }
    }

    /// The outcome a call already has. A planned call has none yet; the error a
    /// rejected one carries is final.
    var result: AgentToolResult {
        switch self {
        case .ready(let ready):
            AgentToolResult(
                callID: ready.invocation.call.id,
                content: String(localized: "The tool call did not produce a result."),
                isError: true
            )
        case .rejected(_, let result):
            result
        }
    }

    var concurrency: AgentToolDescriptor.Concurrency {
        switch self {
        case .ready(let ready): ready.descriptor.concurrency
        // A rejected call runs nothing, so it can conflict with nothing.
        // Calling it parallel keeps one malformed argument list from
        // serializing the whole turn around it.
        case .rejected: .parallel
        }
    }
}

/// What a call whose wait was cut short says to the model.
///
/// Shared by the two ways that happens — the user pressing Stop, and a steered
/// message ending the batch early — because the honest thing to say is the same
/// in both. It must not say the tool did not run: cancelling an `ssh_exec`
/// abandons the channel and gives up the session, it does not stop the command
/// on the far side, and a model told "this never ran" will happily run it again.
/// See the `defer` in `SSHExecSession.executeOnQueue`, which spells out that the
/// command may still be running, and `AgentUnansweredToolCallRepair`, which says
/// the same thing about a process that died.
nonisolated enum AgentInterruptedToolCall {
    static let reason = String(
        localized: """
            Termind stopped waiting for this tool before it finished. Whether the action \
            completed is unknown; check the current state before doing it again.
            """
    )
}

/// Runs a single tool call through every gate, in a fixed order.
///
/// The order is the contract: structural validation, then locally-proven facts,
/// then the card, then hooks, then authorization, then the tool. Nothing the
/// model or a remote server said can move a step earlier, and `willExecute`
/// deliberately sits *before* authorization so a hook can stop a call but never
/// smuggle one past the gate.
nonisolated struct AgentToolExecutor: Sendable {
    let tools: AgentToolRegistry
    let approval: any AgentApprovalHandling
    let hooks: AgentLoopHooks
    let channel: AgentEventChannel
    let secretBroker: SecretBroker
    let userInteraction: any AgentUserInteractionHandling
    let runID: UUID
    let permissionMode: ChatPermissionMode
    let userIntent: String

    func plan(_ call: AgentToolCall) async -> AgentPlannedToolCall {
        let proposed = AgentToolInvocation(runID: runID, call: call)
        guard let tool = tools[call.name] else {
            // Still a card. Returning silently left the transcript showing an
            // empty assistant turn and nothing else, which reads as "the model
            // said nothing" rather than "the model called a tool we do not
            // have" — the one thing the user needs to see here.
            let result = AgentToolResult(
                callID: call.id,
                content: String(localized: "Unknown tool: \(call.name)"),
                isError: true
            )
            channel.emit(.toolProposed(proposed, AgentToolDescriptor(
                name: call.name,
                summary: String(localized: "This tool is not available in this run."),
                inputSchema: .object(["type": .string("object")]),
                target: .local, safety: .requiresAuthorization
            )))
            channel.emit(.toolFinished(proposed, result))
            return .rejected(invocation: proposed, result: result)
        }

        let preflight: AgentToolPreflight
        do {
            try AgentJSONSchemaValidator.validate(
                call.arguments, against: tool.descriptor.inputSchema
            )
            preflight = try await tool.preflight(proposed)
        } catch {
            let result = AgentToolResult(
                callID: call.id,
                content: String(localized: "Tool input was rejected: \(error.localizedDescription)"),
                isError: true
            )
            channel.emit(.toolProposed(proposed, tool.descriptor))
            channel.emit(.toolFinished(proposed, result))
            return .rejected(invocation: proposed, result: result)
        }

        var descriptor = tool.descriptor
        descriptor.safety = preflight.safety
        // Only if preflight had something to say. A tool that does not override
        // keeps whatever it declared.
        if let concurrency = preflight.concurrency { descriptor.concurrency = concurrency }
        channel.emit(.toolProposed(preflight.invocation, descriptor))
        return .ready(AgentPlannedToolCall.Ready(
            tool: tool,
            invocation: preflight.invocation,
            descriptor: descriptor,
            reasons: preflight.reasons,
            executionMetadata: preflight.executionMetadata
        ))
    }

    func execute(_ planned: AgentPlannedToolCall) async -> AgentToolResult {
        // A rejected call's card was raised and finished during planning;
        // re-emitting here would draw it twice.
        guard case .ready(let ready) = planned else { return planned.result }

        let hookDecision = await hooks.willExecute(AgentToolCallContext(
            invocation: ready.invocation, descriptor: ready.descriptor,
            userIntent: userIntent, permissionMode: permissionMode
        ))
        if case .block(let reason) = hookDecision {
            return await finish(ready, AgentToolResult(
                callID: ready.invocation.call.id, content: reason, isError: true
            ))
        }

        let request = AgentApprovalRequest(
            invocation: ready.invocation,
            descriptor: ready.descriptor,
            userIntent: userIntent,
            localReasons: ready.reasons
        )
        switch await approval.authorize(request, mode: permissionMode) {
        case .deny(let reason):
            return await finish(ready, AgentToolResult(
                callID: ready.invocation.call.id, content: reason, isError: true
            ))
        case .allow:
            channel.emit(.toolStarted(ready.invocation))
            do {
                let result = try await ready.tool.execute(
                    ready.invocation, context: context(for: ready)
                )
                return await finish(ready, result)
            } catch is CancellationError {
                // Not `localizedDescription`, which for this error is
                // "The operation couldn't be completed. (Swift.CancellationError
                // error 1.)" — a sentence about Swift, addressed to a model that
                // needs a sentence about the host. And not "it did not run"
                // either: cancelling an `ssh_exec` abandons the channel without
                // stopping the command on the far side, so the outcome is
                // genuinely unknown. Same wording, for the same reason, as
                // `AgentUnansweredToolCallRepair`.
                return await finish(ready, AgentToolResult(
                    callID: ready.invocation.call.id,
                    content: AgentInterruptedToolCall.reason, isError: true
                ))
            } catch {
                return await finish(ready, AgentToolResult(
                    callID: ready.invocation.call.id,
                    content: error.localizedDescription, isError: true
                ))
            }
        }
    }

    /// Refuses a call outright, with a card, without planning or running it.
    ///
    /// The card matters as much as the result. A turn where the model asked for
    /// four things and three cards appeared reads as the fourth having been
    /// quietly ignored; this is what makes "the budget ran out" or "the run was
    /// cancelled" a visible outcome of a specific call.
    func fail(_ call: AgentToolCall, reason: String) -> AgentToolResult {
        let invocation = AgentToolInvocation(runID: runID, call: call)
        let result = AgentToolResult(callID: call.id, content: reason, isError: true)
        let descriptor = tools[call.name]?.descriptor ?? AgentToolDescriptor(
            name: call.name,
            summary: String(localized: "This tool is not available in this run."),
            inputSchema: .object(["type": .string("object")]),
            target: .local, safety: .requiresAuthorization
        )
        channel.emit(.toolProposed(invocation, descriptor))
        channel.emit(.toolFinished(invocation, result))
        return result
    }

    private func context(for ready: AgentPlannedToolCall.Ready) -> AgentToolExecutionContext {
        AgentToolExecutionContext(
            runID: runID,
            userIntent: userIntent,
            secretBroker: secretBroker,
            userInteraction: EventingAgentUserInteraction(
                base: userInteraction, channel: channel
            ),
            preflightMetadata: ready.executionMetadata,
            authorize: { [approval, permissionMode] request in
                await approval.authorize(request, mode: permissionMode)
            },
            report: { [channel, invocation = ready.invocation] partial in
                channel.emit(.toolProgress(invocation, partial))
            }
        )
    }

    /// The single exit. Every result — denied, blocked, thrown, or returned —
    /// passes the `didExecute` hooks and then one `toolFinished`, so a hook can
    /// never see a subset of outcomes and the card can never be left open.
    private func finish(
        _ ready: AgentPlannedToolCall.Ready, _ result: AgentToolResult
    ) async -> AgentToolResult {
        let final = await hooks.didExecute(
            ready.invocation, descriptor: ready.descriptor, result: result
        )
        channel.emit(.toolFinished(ready.invocation, final))
        return final
    }
}

/// Publishes the question a tool is asking, then gets out of the way.
///
/// It raises `userInputRequested` and nothing else. It used to also emit
/// `runState(.waitingForUser)` and `runState(.running)` around the wait, which
/// only worked while one tool ran at a time: with a batch in flight, the tool
/// whose question is answered would announce "running" while another was still
/// waiting on the user. Run state is derived from what is actually outstanding
/// — see `ConversationModel` — rather than asserted by whichever tool moved
/// last.
private nonisolated struct EventingAgentUserInteraction: AgentUserInteractionHandling, Sendable {
    var base: any AgentUserInteractionHandling
    var channel: AgentEventChannel

    func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse {
        channel.emit(.userInputRequested(request))
        return await base.request(request)
    }

    func requestSSHAuthentication(
        _ request: AgentSSHAuthenticationRequest
    ) async -> AgentSSHAuthenticationResponse {
        // The request is locally derived rather than model-authored. The
        // conversation queues it directly; deliberately no event or durable
        // record is produced on the path that will return credentials.
        await base.requestSSHAuthentication(request)
    }
}
