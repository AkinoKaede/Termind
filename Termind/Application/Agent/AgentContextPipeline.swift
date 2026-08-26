import Foundation

/// What a run is about to send, before it becomes any provider's wire format.
///
/// The other half of the boundary — turning this into Responses / Chat
/// Completions / Messages / Gemini JSON — already exists inside
/// `AgentProviderClient`. This type is what sits in front of it: everything
/// that is true regardless of which provider is about to receive it.
nonisolated struct AgentModelContext: Sendable {
    var systemPrompt: String
    var messages: [AgentTranscriptMessage]
    var tools: [AgentToolDescriptor]
}

/// One rewrite applied at the model-call boundary.
///
/// Transforms shape what is *sent*, never what is *kept*: `AgentRunSnapshot`
/// and the stored transcript are written before this runs and are unaffected by
/// it. That separation is what lets history stay complete while the request
/// stays affordable.
nonisolated protocol AgentContextTransforming: Sendable {
    func transform(_ context: AgentModelContext) -> AgentModelContext
}

/// An ordered chain of transforms. Composition is the extension point: adding a
/// rewrite means adding an element here, not editing the loop.
nonisolated struct AgentContextPipeline: Sendable {
    var transforms: [any AgentContextTransforming]

    init(_ transforms: [any AgentContextTransforming]) {
        self.transforms = transforms
    }

    func callAsFunction(_ context: AgentModelContext) -> AgentModelContext {
        transforms.reduce(context) { $1.transform($0) }
    }

    /// What a chat run uses.
    ///
    /// Order matters. The unanswered repair runs first so the results it
    /// invents are sorted into place by the step after it; ordering runs before
    /// the orphan repair so a reordered block is what gets checked; trimming
    /// runs after all three so it measures the results that will actually be
    /// sent; injection runs last because everything before it reasons about
    /// tool results sitting directly behind their assistant turn.
    static func chat(
        sessionContext: AgentTranscriptMessage?,
        before promptID: AgentTranscriptMessage.ID?
    ) -> AgentContextPipeline {
        AgentContextPipeline([
            AgentUnansweredToolCallRepair(),
            AgentToolResultOrdering(),
            AgentOrphanedToolResultRepair(),
            AgentToolResultTrimming(),
            AgentSessionContextInjection(message: sessionContext, before: promptID),
        ])
    }
}

// MARK: - Ordering

/// Puts each turn's tool results back into the order the assistant asked for
/// them.
///
/// Necessary the moment tools stop running one at a time. `AgentRuntime`
/// appends results to its snapshot in source order, but `ConversationModel`
/// appends them as `toolFinished` events arrive — which under parallel
/// execution is completion order. Those two transcripts then disagree, and the
/// conversation's copy is the one replayed as the next run's `priorMessages`.
///
/// Repairing it here rather than in either writer means one implementation, one
/// test, and both paths fixed. Results are matched to their call by id; a
/// result whose id names no call in the turn above it keeps its place, and
/// `AgentOrphanedToolResultRepair` is what deals with it.
nonisolated struct AgentToolResultOrdering: AgentContextTransforming {
    func transform(_ context: AgentModelContext) -> AgentModelContext {
        var result = context
        var index = 0
        while index < result.messages.count {
            guard result.messages[index].role == .assistant,
                !result.messages[index].toolCalls.isEmpty
            else {
                index += 1
                continue
            }
            let order = result.messages[index].toolCalls.map(\.id)
            let start = index + 1
            var end = start
            while end < result.messages.count, result.messages[end].role == .tool {
                end += 1
            }
            guard end > start else {
                index += 1
                continue
            }
            let block = Array(result.messages[start..<end])
            // A stable sort by the call's position. Anything the turn did not
            // ask for sorts to the end rather than to an arbitrary slot.
            let ranked = block.enumerated().sorted { left, right in
                let leftRank = left.element.toolCallID.flatMap { order.firstIndex(of: $0) }
                    ?? order.count
                let rightRank = right.element.toolCallID.flatMap { order.firstIndex(of: $0) }
                    ?? order.count
                if leftRank != rightRank { return leftRank < rightRank }
                return left.offset < right.offset
            }
            result.messages.replaceSubrange(start..<end, with: ranked.map(\.element))
            index = end
        }
        return result
    }
}

// MARK: - Orphan repair

/// Drops tool results that answer no call in the same history.
///
/// A `tool` message only means anything beside the assistant turn that asked
/// for it. One left on its own is rejected outright — OpenAI answers
/// `No tool call found for function call output with call_id ...`, and the
/// other two reject the equivalent — so a single orphan makes a conversation
/// permanently unusable rather than degrading it.
///
/// `AgentRuntime` also applies this to incoming history when it seeds a run's
/// snapshot, which is what makes it a repair and not just a guard: filtering
/// there stops a stored orphan from being written forward into the next run.
/// Here it is the boundary's own guarantee, for a transcript assembled by
/// anyone.
///
/// Messages with no call id at all are kept. Google addresses a tool result by
/// name rather than by id, so absence here is not evidence of an orphan.
nonisolated struct AgentOrphanedToolResultRepair: AgentContextTransforming {
    func transform(_ context: AgentModelContext) -> AgentModelContext {
        var result = context
        result.messages = Self.apply(result.messages)
        return result
    }

    static func apply(_ messages: [AgentTranscriptMessage]) -> [AgentTranscriptMessage] {
        let answered = Set(
            messages.lazy
                .filter { $0.role == .assistant }
                .flatMap { $0.toolCalls.map(\.id) }
        )
        return messages.filter { message in
            guard message.role == .tool, let id = message.toolCallID, !id.isEmpty else {
                return true
            }
            return answered.contains(id)
        }
    }
}

// MARK: - Unanswered calls

/// Answers tool calls that nothing ever answered.
///
/// The mirror of `AgentOrphanedToolResultRepair`, and the same class of fatal:
/// where a result with no call is rejected, so is a call with no result. OpenAI
/// says `No tool output found for function call call_…`, and the other two
/// reject the equivalent — the conversation cannot be continued at all after
/// that, only deleted.
///
/// The gap this closes is a process that dies mid-batch. A live run always
/// answers every call, cancellation included — see `AgentToolScheduler` — but a
/// force quit, a crash, or the OS reclaiming the app takes the run's remaining
/// writes with it, and the history restored at launch has an assistant turn
/// with nothing behind it.
///
/// The wording matters as much as the presence. It must not say the tool did
/// not run: the process died *after* the command was dispatched, so whether the
/// remote side executed it is genuinely unknown, and a model told "this never
/// ran" will happily run it again. Telling it to check first is the only honest
/// instruction, and the only safe one when the call was `rm`.
nonisolated struct AgentUnansweredToolCallRepair: AgentContextTransforming {
    func transform(_ context: AgentModelContext) -> AgentModelContext {
        var result = context
        result.messages = Self.apply(result.messages)
        return result
    }

    static func apply(_ messages: [AgentTranscriptMessage]) -> [AgentTranscriptMessage] {
        guard messages.contains(where: { $0.role == .assistant && !$0.toolCalls.isEmpty })
        else { return messages }

        var repaired: [AgentTranscriptMessage] = []
        repaired.reserveCapacity(messages.count)
        var index = messages.startIndex
        while index < messages.endIndex {
            let message = messages[index]
            repaired.append(message)
            index += 1
            guard message.role == .assistant, !message.toolCalls.isEmpty else { continue }

            var answered: Set<String> = []
            while index < messages.endIndex, messages[index].role == .tool {
                if let id = messages[index].toolCallID { answered.insert(id) }
                repaired.append(messages[index])
                index += 1
            }
            for call in message.toolCalls where !answered.contains(call.id) {
                repaired.append(AgentTranscriptMessage(
                    role: .tool, text: interrupted, toolCallID: call.id,
                    toolName: call.name, isError: true
                ))
            }
        }
        return repaired
    }

    private static let interrupted = String(
        localized: """
            Termind stopped before this tool call's result was recorded. Whether the action \
            completed is unknown; check the current state before doing it again.
            """
    )
}

// MARK: - Trimming

/// Bounds what replaying old tool results costs.
///
/// `ssh_exec` returns up to 256 KB and `sftp_read` up to 128 KB, and every one
/// of those is sent again on every later turn of the conversation — up to
/// `maxTurns` times. Two log reads are enough to crowd out the conversation
/// they were meant to explain.
///
/// The invariant is that **at most one turn's tool output is ever replayed in
/// full**, and it is the most recent one — normally the output the model is
/// still reasoning about. Everything older keeps its head and its tail: a
/// truncated command output whose ending is missing loses the error message,
/// which is usually the only part that mattered.
///
/// Only `tool` messages are touched. What the user wrote and what the assistant
/// concluded stay whole at any age — the conclusion is frequently the compact
/// form of the output being trimmed underneath it.
nonisolated struct AgentToolResultTrimming: AgentContextTransforming {
    /// Generous on purpose. This is a ceiling on pathological replay, not a
    /// context budget: a result that fits is never altered.
    var limit: Int = 8_192

    func transform(_ context: AgentModelContext) -> AgentModelContext {
        var result = context
        // Everything after the newest assistant turn that called tools is that
        // turn's output, and stays whole.
        let recent = result.messages.lastIndex {
            $0.role == .assistant && !$0.toolCalls.isEmpty
        }
        for index in result.messages.indices {
            guard result.messages[index].role == .tool else { continue }
            if let recent, index > recent { continue }
            result.messages[index].text = Self.trimmed(result.messages[index].text, limit: limit)
        }
        return result
    }

    static func trimmed(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = limit * 5 / 8
        let tail = limit - head
        let dropped = text.count - limit
        return text.prefix(head)
            + "\n[… \(dropped) characters trimmed from an earlier turn …]\n"
            + text.suffix(tail)
    }
}

// MARK: - Session context

/// Puts the session context into what is *sent* without putting it into what is
/// *kept*.
///
/// The durable transcript is where a context block must not go: it would be
/// persisted, replayed, and — since restore projects user rows into the visible
/// list — eventually shown in the user's own chat bubble. Dropping it costs the
/// next run one uncached message at the tail and nothing before it, because
/// history the model already saw is unchanged either way.
///
/// It rides the tail of the message list rather than the system prompt. Every
/// cache these providers keep is a *prefix* cache, and the working directory of
/// a terminal is the most volatile thing we know: one `cd` between turns used
/// to change byte zero of the request and miss the entire replayed
/// conversation. Here the divergence is the newest turn, which was never
/// cacheable anyway, and the system prompt stays byte-identical across every
/// run, conversation, and user.
///
/// Anchored to the prompt's identity rather than to a captured index. An index
/// is only correct as long as nothing ahead of it is ever added or removed, and
/// the transforms that run before this one are free to do both.
nonisolated struct AgentSessionContextInjection: AgentContextTransforming {
    var message: AgentTranscriptMessage?
    var before: AgentTranscriptMessage.ID?

    init(message: AgentTranscriptMessage?, before: AgentTranscriptMessage.ID?) {
        self.message = message
        self.before = before
    }

    func transform(_ context: AgentModelContext) -> AgentModelContext {
        guard let message, let before,
            let index = context.messages.firstIndex(where: { $0.id == before })
        else { return context }
        var result = context
        result.messages.insert(message, at: index)
        return result
    }
}
