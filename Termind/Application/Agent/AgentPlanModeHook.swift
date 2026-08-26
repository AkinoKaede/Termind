import Foundation

/// Plan mode, as a loop hook.
///
/// A hook rather than a fourth `ChatPermissionMode` because the two answer
/// different questions and compose: permission mode decides *who authorizes* an
/// action, plan mode decides *whether the action is on the table at all*. Hooks
/// run before authorization ([AgentLoopHook]), so this can only ever tighten —
/// there is no arrangement of it that routes a call past
/// `AgentApprovalHandling`.
///
/// A plain value, not an actor. A run's posture is fixed when it starts:
/// `present_plan` ends the turn rather than flipping a flag inside it, and
/// implementing a plan is a new run. Nothing here mutates.
nonisolated struct AgentPlanModeHook: AgentLoopHook {
    let isPlanning: Bool

    /// Tools refused by name rather than by safety.
    ///
    /// `manage_tasks` is `.locallyReadOnly` — it changes nothing, so the safety
    /// gate has no reason to stop it — and it still has no business running
    /// here. `pi-plan-mode` blocks Pi's `update_plan` during planning "because
    /// it tracks execution progress rather than conversational planning", and
    /// the same holds: nothing is executing yet, so a task list would be a
    /// checklist of things that have not started, sitting beside a plan that has
    /// not been agreed to.
    static let blockedByName: Set<String> = ["manage_tasks"]

    /// Named here rather than matched as a string at the call sites that care.
    static let presentPlanToolName = "present_plan"
    static let sshExecToolName = "ssh_exec"

    func willExecute(_ context: AgentToolCallContext) async -> AgentToolCallDecision {
        guard isPlanning else { return .proceed }

        let name = context.invocation.call.name
        if Self.blockedByName.contains(name) {
            return .block(reason: String(
                localized: """
                    \(name) is unavailable while planning: nothing has been agreed to yet, so \
                    there is no work to track. Finish the plan and call present_plan.
                    """
            ))
        }

        // `ssh_exec` is judged on what the command would *do*, not on who has to
        // authorize it — and that difference is the point of the mode rather
        // than a hole in it. Reading a server's state is most of planning, and
        // `CommandRiskClassifier` fails closed: anything not on its read-only
        // list, `systemctl list-timers` and `dpkg -l` included, comes back
        // `.caution`. Refusing those would leave the agent guessing at the state
        // it is supposed to be planning against, which is worse than useless.
        //
        // So the bar is *destructive*, not *provably safe*. A command the
        // classifier cannot vouch for still meets the approval gate exactly as
        // it would outside plan mode — the user sees it under Ask for approval,
        // Security Review sees it under Approve for me. Full access skips that,
        // as it does everywhere else; plan mode is a posture, not a sandbox, and
        // the one thing it refuses outright even there is a command that
        // destroys something.
        if name == Self.sshExecToolName {
            let command = context.invocation.call.arguments
                .objectValue?["command"]?.stringValue ?? ""
            let assessment = CommandRiskClassifier.assess(command)
            guard assessment.risk == .destructive else { return .proceed }
            return .block(reason: String(
                localized: """
                    Plan mode is on, so this command was not run — it is destructive. \
                    \(assessment.reasons.joined(separator: " ")) Read the state you need \
                    another way, put it in the plan, and let the user run it.
                    """
            ))
        }

        // `context.descriptor` is post-preflight, so the rest rides evidence the
        // pipeline already proved locally rather than anything the model or a
        // remote server asserted. `scratch_write` and `scratch_edit` are
        // contained; every SFTP write, `scratch_push`, a private-network
        // `fetch`, and every MCP tool are not.
        guard !context.descriptor.safety.isAllowedWhilePlanning else { return .proceed }
        return .block(reason: String(
            localized: """
                Plan mode is on, so \(name) was not run — it changes something outside \
                Termind. Investigate with reads, draft the plan in the scratch workspace, and \
                call present_plan. The user runs it, or not, from there.
                """
        ))
    }

    /// Ends the run on the turn that presented a plan.
    ///
    /// `pi-plan-mode`'s `terminate: true`, through the seam this codebase
    /// already has. `shouldStop` stops *after* the turn completes rather than
    /// abandoning it, so every call in the batch is still answered and the
    /// transcript stays replayable.
    ///
    /// Not conditional on `isPlanning`: a plan presented outside plan mode is a
    /// plan the user still has to answer, and continuing past it would act on
    /// something nobody agreed to.
    func shouldStop(after summary: AgentTurnSummary) async -> Bool {
        summary.message.toolCalls.contains { $0.name == Self.presentPlanToolName }
    }
}

/// The instructions a planning run is given, injected at the model boundary.
///
/// A message rather than a different system prompt, following `pi-plan-mode`
/// ("one hidden, model-visible, versioned Plan contract before the first Plan
/// prompt"). The reason is the one `AgentSessionContextInjection` already
/// documents: every provider cache is a *prefix* cache, so a system prompt that
/// changed with the mode would miss the whole replayed conversation on every
/// toggle. `AgentSystemPrompt.default` stays byte-identical for every run.
nonisolated struct AgentPlanContractInjection: AgentContextTransforming {
    var isPlanning: Bool
    /// The turn this sits in front of, by identity rather than index — the
    /// transforms ahead of this one are free to add and remove messages.
    var before: AgentTranscriptMessage.ID?

    func transform(_ context: AgentModelContext) -> AgentModelContext {
        guard isPlanning, let before,
            let index = context.messages.firstIndex(where: { $0.id == before })
        else { return context }
        var result = context
        result.messages.insert(
            AgentTranscriptMessage(role: .user, text: Self.contract), at: index
        )
        return result
    }

    static let contract = """
        Plan mode is on for this turn. You are designing a change, not making one.

        Investigate freely. Run the commands you need to understand the machine — ssh_exec is \
        available and is not limited to a fixed list, so inspect services, logs, packages and \
        configuration as you would normally. A command that changes something may pause for the \
        user's approval; one that destroys something is refused outright. SFTP reads, fetch and \
        search all work.

        What is refused is changing anything: writing or deleting remote files, pushing from \
        the scratch workspace, and every MCP tool. Do not attempt those, and never describe an \
        action as taken — you have taken none.

        Draft the plan in the scratch workspace with scratch_write, and revise it there with \
        scratch_edit rather than rewriting it. That way a revision costs a diff instead of \
        another copy of the document.

        When a choice is genuinely the user's — which host is production, which of two \
        approaches to take, a tradeoff with no defensible default — ask with \
        request_user_input, giving real options and saying what each one costs. Resolve those \
        before you finish, not after: a plan built on a guess is one they have to unpick. \
        Decide anything the conversation or an obvious convention already answers, and say \
        which assumption you used.

        When the approach is settled, call present_plan with the scratch path, on its own and \
        as the last thing you do. The run ends there and the user decides whether to \
        implement it.
        """
}
