import Foundation

nonisolated enum AgentToolExecutionMode: String, Hashable, Sendable, Codable {
    case parallel
    case sequential
}

/// Runs one turn's tool calls and hands back exactly one result per call, in
/// the order the model asked for them.
///
/// Two guarantees hold on every path, including cancellation and budget
/// failures:
///
/// - **One result per call.** An assistant turn carrying tool calls that some
///   of its results do not answer is rejected outright by every provider, so a
///   run that gave up halfway used to leave the conversation permanently
///   unusable rather than merely interrupted.
/// - **Source order.** Completion order is whatever the network decided;
///   `toolFinished` events follow it, because that is when the card should
///   stop spinning. What goes into the transcript does not.
nonisolated struct AgentToolScheduler: Sendable {
    let executor: AgentToolExecutor
    /// The run-wide default. A tool can only make its batch stricter, never
    /// looser — see `resolved(_:)`.
    var mode: AgentToolExecutionMode = .parallel
    /// Eight concurrent SSH channels and HTTP connections is already more than
    /// a person asked for. A model that requests thirty reads gets them all,
    /// eight at a time, rather than thirty sockets at once.
    var maximumConcurrency = 8

    func run(
        _ calls: [AgentToolCall], sourceMessageID: UUID? = nil
    ) async -> [AgentToolResult] {
        guard !calls.isEmpty else { return [] }

        var plan: [AgentPlannedToolCall] = []
        plan.reserveCapacity(calls.count)
        for call in calls {
            // Planning stops at cancellation, but the calls behind it still get
            // a card and a result — silence would leave the model with calls
            // nothing ever answered.
            guard !Task.isCancelled else { break }
            plan.append(await executor.plan(call, sourceMessageID: sourceMessageID))
        }
        guard plan.count == calls.count else {
            // Whatever was already planned still runs to completion — it may
            // have started before the cancellation — and the rest are refused.
            return await sequential(plan)
                + cancelled(Array(calls[plan.count...]), sourceMessageID: sourceMessageID)
        }

        // Pi's rule, and the reason a batch is all-or-nothing rather than
        // segmented: one call that must not run beside anything makes the whole
        // turn serial. Segmenting around it would buy back only the cross-host
        // case — same-host `ssh_exec` and SFTP already serialize inside their
        // session actors — in exchange for semantics nobody can hold in their
        // head while reading an incident transcript.
        switch resolved(plan) {
        case .sequential: return await sequential(plan)
        case .parallel: return await parallel(plan)
        }
    }

    /// Every call fails without running, each still drawn as a card.
    ///
    /// Used where the turn is refused as a whole: the tool budget is spent, or
    /// the provider truncated the response mid-arguments. Salvaged arguments
    /// can parse and validate and still be silently incomplete, so a truncated
    /// call is never executed.
    func fail(
        _ calls: [AgentToolCall], reason: String, sourceMessageID: UUID? = nil
    ) -> [AgentToolResult] {
        calls.map { executor.fail($0, reason: reason, sourceMessageID: sourceMessageID) }
    }

    private func resolved(_ plan: [AgentPlannedToolCall]) -> AgentToolExecutionMode {
        guard mode == .parallel else { return .sequential }
        return plan.contains { $0.concurrency == .sequential } ? .sequential : .parallel
    }

    private func cancelled(
        _ calls: [AgentToolCall], sourceMessageID: UUID?
    ) -> [AgentToolResult] {
        let reason = String(localized: "The run was cancelled before this tool ran.")
        return calls.map {
            executor.fail($0, reason: reason, sourceMessageID: sourceMessageID)
        }
    }

    private func sequential(_ plan: [AgentPlannedToolCall]) async -> [AgentToolResult] {
        var results: [AgentToolResult] = []
        results.reserveCapacity(plan.count)
        for planned in plan {
            results.append(await executor.execute(planned))
        }
        return results
    }

    private func parallel(_ plan: [AgentPlannedToolCall]) async -> [AgentToolResult] {
        await withTaskGroup(of: (Int, AgentToolResult).self) { group in
            var completed: [Int: AgentToolResult] = [:]
            var next = 0
            while next < min(maximumConcurrency, plan.count) {
                let index = next
                group.addTask { [executor] in (index, await executor.execute(plan[index])) }
                next += 1
            }
            while let (index, result) = await group.next() {
                completed[index] = result
                guard next < plan.count else { continue }
                let scheduled = next
                group.addTask { [executor] in (scheduled, await executor.execute(plan[scheduled])) }
                next += 1
            }
            // Rebuilt from the plan rather than from completion order, and with
            // a stated fallback rather than a `compactMap` that would quietly
            // return fewer results than there were calls.
            return plan.indices.map { completed[$0] ?? plan[$0].result }
        }
    }
}
