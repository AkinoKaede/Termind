import Foundation
import SwiftData

@Model
final class PersistentAgentConversation {
    @Attribute(.unique) var id: UUID = UUID()
    var title = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(id: UUID, title: String, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class PersistentAgentRun {
    @Attribute(.unique) var id: UUID = UUID()
    var conversationID: UUID = UUID()
    var state = AgentRunState.idle.rawValue
    var permissionMode = ChatPermissionMode.askForApproval.rawValue
    var startedAt: Date = Date()
    var finishedAt: Date?
    var failure: String?

    init(_ snapshot: AgentRunSnapshot) {
        id = snapshot.id
        update(snapshot)
    }

    func update(_ snapshot: AgentRunSnapshot) {
        conversationID = snapshot.conversationID
        state = snapshot.state.rawValue
        permissionMode = snapshot.permissionMode.rawValue
        startedAt = snapshot.startedAt
        finishedAt = snapshot.finishedAt
        failure = snapshot.failure.map(AgentPersistenceRedactor.visibleText)
    }
}

@Model
final class PersistentAgentMessage {
    @Attribute(.unique) var id: UUID = UUID()
    var runID: UUID = UUID()
    var role = AgentTranscriptRole.user.rawValue
    var text = ""
    var toolCallsData = Data()
    var toolCallID: String?
    var toolName: String?
    var isError = false
    var createdAt: Date = Date()

    init(_ message: AgentTranscriptMessage, runID: UUID) {
        id = message.id
        self.runID = runID
        role = message.role.rawValue
        text = AgentPersistenceRedactor.visibleText(message.text)
        toolCallsData = AgentPersistenceRedactor.encoded(message.toolCalls.map { call in
            AgentToolCall(
                id: call.id, name: call.name,
                arguments: AgentPersistenceRedactor.redactedJSON(call.arguments),
                providerItemID: call.providerItemID
            )
        })
        toolCallID = message.toolCallID
        toolName = message.toolName
        isError = message.isError
        createdAt = message.createdAt
    }
}

@Model
final class PersistentAgentToolInvocation {
    @Attribute(.unique) var id: UUID = UUID()
    var runID: UUID = UUID()
    var callID = ""
    var toolName = ""
    var argumentsData = Data()
    var targetHostID: UUID?
    var state = "proposed"
    var createdAt: Date = Date()

    init(_ invocation: AgentToolInvocation, state: String) {
        id = invocation.id
        runID = invocation.runID
        callID = invocation.call.id
        toolName = invocation.call.name
        argumentsData = AgentPersistenceRedactor.redactedJSON(invocation.call.arguments).encodedData
        targetHostID = invocation.targetHostID
        self.state = state
        createdAt = invocation.createdAt
    }
}

@Model
final class PersistentAgentToolResult {
    @Attribute(.unique) var id: UUID = UUID()
    var runID: UUID = UUID()
    var invocationID: UUID = UUID()
    var callID = ""
    var content = ""
    var isError = false
    var isTruncated = false
    var metadataData = Data()

    init(_ result: AgentToolResult, invocation: AgentToolInvocation) {
        runID = invocation.runID
        invocationID = invocation.id
        callID = result.callID
        content = AgentPersistenceRedactor.visibleText(result.content)
        isError = result.isError
        isTruncated = result.isTruncated || content.count < result.content.count
        metadataData = AgentPersistenceRedactor.encoded(result.metadata)
    }
}

@Model
final class PersistentAgentReviewRecord {
    @Attribute(.unique) var id: UUID = UUID()
    var runID: UUID = UUID()
    var invocationID: UUID = UUID()
    var status = "started"
    var verdict: String?
    var risk: String?
    var userAuthorization: String?
    var reason: String?
    var createdAt: Date = Date()

    init(runID: UUID, invocationID: UUID, decision: SecurityReviewDecision?) {
        self.runID = runID
        self.invocationID = invocationID
        if let decision {
            status = "finished"
            verdict = decision.verdict.rawValue
            risk = decision.risk.rawValue
            userAuthorization = decision.userAuthorization.rawValue
            reason = AgentPersistenceRedactor.visibleText(decision.reason)
        }
    }

    init(runID: UUID, invocationID: UUID, failure: String, timedOut: Bool) {
        self.runID = runID
        self.invocationID = invocationID
        status = timedOut ? "timedOut" : "failed"
        reason = AgentPersistenceRedactor.visibleText(failure)
    }
}

@MainActor
final class SwiftDataAgentRunRepository: AgentRunPersisting, Sendable {
    private let context: ModelContext
    private var deletedConversationIDs = Set<UUID>()
    private var deletedRunIDs = Set<UUID>()

    init(context: ModelContext) {
        self.context = context
        interruptUnfinishedRuns()
    }

    @MainActor
    func save(_ snapshot: AgentRunSnapshot) async throws {
        guard !deletedConversationIDs.contains(snapshot.conversationID) else {
            deletedRunIDs.insert(snapshot.id)
            return
        }
        let runID = snapshot.id
        let runDescriptor = FetchDescriptor<PersistentAgentRun>(predicate: #Predicate { $0.id == runID })
        if let row = try context.fetch(runDescriptor).first { row.update(snapshot) }
        else { context.insert(PersistentAgentRun(snapshot)) }

        let conversationID = snapshot.conversationID
        let conversationDescriptor = FetchDescriptor<PersistentAgentConversation>(
            predicate: #Predicate { $0.id == conversationID }
        )
        // No title seeding here. `title` means "the generated summary", and
        // empty means there is not one yet — which is what lets the UI decide to
        // fall back to the opening line rather than having that line frozen into
        // storage as though it were a name someone chose.
        if let conversation = try context.fetch(conversationDescriptor).first {
            conversation.updatedAt = .now
        } else {
            context.insert(PersistentAgentConversation(
                id: conversationID, title: "", createdAt: snapshot.startedAt
            ))
        }

        // Matched on message id, not on this run's id. A conversation's earlier
        // turns are replayed into every later run, so filtering by `runID` made
        // each save re-insert the whole history — colliding with the unique
        // constraint and rewriting rows that were already correct.
        let ids = Set(snapshot.messages.map(\.id))
        let stored = try context.fetch(FetchDescriptor<PersistentAgentMessage>(
            predicate: #Predicate { ids.contains($0.id) }
        ))
        let storedIDs = Set(stored.map(\.id))
        var inserted = false
        for message in snapshot.messages where !storedIDs.contains(message.id) {
            context.insert(PersistentAgentMessage(message, runID: runID))
            inserted = true
        }
        guard inserted || context.hasChanges else { return }
        try context.save()
    }

    @MainActor
    func record(_ event: AgentEvent, runID: UUID) async throws {
        guard !deletedRunIDs.contains(runID) else { return }
        switch event {
        case .toolProposed(let invocation, _):
            try upsertInvocation(invocation, state: "proposed")
        case .toolStarted(let invocation):
            try upsertInvocation(invocation, state: "started")
        case .toolFinished(let invocation, let result):
            try upsertInvocation(invocation, state: "finished")
            context.insert(PersistentAgentToolResult(result, invocation: invocation))
        case .reviewStarted(let request):
            context.insert(PersistentAgentReviewRecord(
                runID: runID, invocationID: request.invocation.id, decision: nil
            ))
        case .reviewFinished(let request, let decision):
            context.insert(PersistentAgentReviewRecord(
                runID: runID, invocationID: request.invocation.id, decision: decision
            ))
        case .reviewFailed(let request, let reason, let timedOut):
            context.insert(PersistentAgentReviewRecord(
                runID: runID, invocationID: request.invocation.id,
                failure: reason, timedOut: timedOut
            ))
        default:
            // Nothing to write, so nothing to save. `AgentRuntime` already
            // filters on `isDurable`; this is the second half of the same
            // guarantee, for any caller that does not.
            return
        }
        try context.save()
    }

    @MainActor
    func loadConversations() async throws -> [StoredAgentConversation] {
        let conversations = try context.fetch(FetchDescriptor<PersistentAgentConversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        ))
        let runs = try context.fetch(FetchDescriptor<PersistentAgentRun>())
        let messages = try context.fetch(FetchDescriptor<PersistentAgentMessage>())
        let invocations = try context.fetch(FetchDescriptor<PersistentAgentToolInvocation>())
        let results = try context.fetch(FetchDescriptor<PersistentAgentToolResult>())
        let reviews = try context.fetch(FetchDescriptor<PersistentAgentReviewRecord>())
        return conversations.map { conversation in
            let matchingRuns = runs.filter { $0.conversationID == conversation.id }
                .sorted { $0.startedAt < $1.startedAt }
            let runIDs = Set(matchingRuns.map(\.id))
            // Ordered by run first, then by time within it. Sorting the whole
            // conversation on `createdAt` alone let two runs interleave whenever
            // their message timestamps were close, which reorders a transcript
            // the model is about to be shown.
            let runOrder = Dictionary(
                uniqueKeysWithValues: matchingRuns.enumerated().map { ($0.element.id, $0.offset) }
            )
            let transcript = messages.filter { runIDs.contains($0.runID) }
                .sorted { lhs, rhs in
                    let left = runOrder[lhs.runID] ?? 0
                    let right = runOrder[rhs.runID] ?? 0
                    if left != right { return left < right }
                    return lhs.createdAt < rhs.createdAt
                }
                .compactMap { row -> AgentTranscriptMessage? in
                    guard let role = AgentTranscriptRole(rawValue: row.role) else { return nil }
                    let calls = (try? JSONDecoder().decode(
                        [AgentToolCall].self, from: row.toolCallsData
                    )) ?? []
                    return AgentTranscriptMessage(
                        id: row.id, role: role, text: row.text, toolCalls: calls,
                        toolCallID: row.toolCallID, toolName: row.toolName,
                        isError: row.isError, createdAt: row.createdAt
                    )
                }
            let state = matchingRuns.last.flatMap { AgentRunState(rawValue: $0.state) }
                ?? .completed
            let cards = invocations.filter { runIDs.contains($0.runID) }
                .sorted { $0.createdAt < $1.createdAt }
                .compactMap { storedToolCard($0, results: results, reviews: reviews) }
            return StoredAgentConversation(
                id: conversation.id,
                messages: Self.recovering(
                    transcript,
                    results: results.filter { runIDs.contains($0.runID) },
                    invocations: invocations.filter { runIDs.contains($0.runID) }
                ),
                toolCards: cards,
                lastRunState: state, title: conversation.title
            )
        }
    }

    @MainActor
    func setTitle(_ title: String, conversationID: UUID) async throws {
        guard !deletedConversationIDs.contains(conversationID) else { return }
        let descriptor = FetchDescriptor<PersistentAgentConversation>(
            predicate: #Predicate { $0.id == conversationID }
        )
        // A title is model output about remote-influenced text, so it goes
        // through the same redaction every other stored string does.
        guard let row = try context.fetch(descriptor).first else { return }
        row.title = AgentPersistenceRedactor.visibleText(String(title.prefix(80)))
        row.updatedAt = .now
        try context.save()
    }

    @MainActor
    func deleteConversation(_ id: UUID) async throws {
        deletedConversationIDs.insert(id)
        let runs = try context.fetch(FetchDescriptor<PersistentAgentRun>())
            .filter { $0.conversationID == id }
        let runIDs = Set(runs.map(\.id))
        deletedRunIDs.formUnion(runIDs)

        for row in try context.fetch(FetchDescriptor<PersistentAgentToolResult>())
            where runIDs.contains(row.runID)
        {
            context.delete(row)
        }
        for row in try context.fetch(FetchDescriptor<PersistentAgentReviewRecord>())
            where runIDs.contains(row.runID)
        {
            context.delete(row)
        }
        for row in try context.fetch(FetchDescriptor<PersistentAgentToolInvocation>())
            where runIDs.contains(row.runID)
        {
            context.delete(row)
        }
        for row in try context.fetch(FetchDescriptor<PersistentAgentMessage>())
            where runIDs.contains(row.runID)
        {
            context.delete(row)
        }
        for row in runs { context.delete(row) }

        let conversations = try context.fetch(FetchDescriptor<PersistentAgentConversation>())
        for row in conversations where row.id == id { context.delete(row) }
        try context.save()
    }

    /// Puts back tool results that were recorded but never made it into the
    /// transcript.
    ///
    /// The two are written on different schedules: a result row lands as its
    /// tool finishes, while its transcript row waits for the run's next
    /// snapshot save. A process killed in between — force quit, crash, the OS
    /// reclaiming the app — leaves the call answered in storage and unanswered
    /// in history, and an assistant turn with an unanswered call is rejected
    /// outright on the next request.
    ///
    /// `AgentUnansweredToolCallRepair` would invent a placeholder for the same
    /// gap, and does for anything still missing after this. Doing it here first
    /// is what gives the model the output the tool actually produced instead of
    /// being told the outcome is unknown when it is sitting in the database.
    static func recovering(
        _ transcript: [AgentTranscriptMessage],
        results: [PersistentAgentToolResult],
        invocations: [PersistentAgentToolInvocation]
    ) -> [AgentTranscriptMessage] {
        guard transcript.contains(where: { $0.role == .assistant && !$0.toolCalls.isEmpty })
        else { return transcript }

        let names = Dictionary(
            invocations.map { ($0.callID, $0.toolName) }, uniquingKeysWith: { first, _ in first }
        )
        var recovered: [AgentTranscriptMessage] = []
        recovered.reserveCapacity(transcript.count)
        var index = transcript.startIndex
        while index < transcript.endIndex {
            let message = transcript[index]
            recovered.append(message)
            index += 1
            guard message.role == .assistant, !message.toolCalls.isEmpty else { continue }

            var answered: Set<String> = []
            while index < transcript.endIndex, transcript[index].role == .tool {
                if let id = transcript[index].toolCallID { answered.insert(id) }
                recovered.append(transcript[index])
                index += 1
            }
            for call in message.toolCalls where !answered.contains(call.id) {
                // The last recorded one: a call id is unique to its invocation,
                // so more than one row can only mean a rewritten result.
                guard let stored = results.last(where: { $0.callID == call.id }) else { continue }
                recovered.append(AgentTranscriptMessage(
                    role: .tool, text: stored.content, toolCallID: call.id,
                    toolName: names[call.id] ?? call.name, isError: stored.isError
                ))
            }
        }
        return recovered
    }

    private func upsertInvocation(
        _ invocation: AgentToolInvocation, state: String
    ) throws {
        let id = invocation.id
        let fetch = FetchDescriptor<PersistentAgentToolInvocation>(
            predicate: #Predicate { $0.id == id }
        )
        if let row = try context.fetch(fetch).first {
            let rank = ["proposed": 0, "started": 1, "finished": 2]
            if rank[state, default: 0] > rank[row.state, default: 0] { row.state = state }
        } else {
            context.insert(PersistentAgentToolInvocation(invocation, state: state))
        }
    }

    private func storedToolCard(
        _ row: PersistentAgentToolInvocation,
        results: [PersistentAgentToolResult],
        reviews: [PersistentAgentReviewRecord]
    ) -> StoredAgentToolCard? {
        guard let arguments = try? AgentJSONValue.decode(row.argumentsData) else { return nil }
        let invocation = AgentToolInvocation(
            id: row.id, runID: row.runID,
            call: AgentToolCall(id: row.callID, name: row.toolName, arguments: arguments),
            targetHostID: row.targetHostID, createdAt: row.createdAt
        )
        let descriptor = AgentToolDescriptor(
            name: row.toolName, summary: row.toolName,
            inputSchema: .object(["type": .string("object")]),
            target: row.targetHostID == nil ? .local : .host,
            safety: .requiresAuthorization
        )
        let result = results.last(where: { $0.invocationID == row.id }).map { stored in
            AgentToolResult(
                callID: stored.callID, content: stored.content,
                isError: stored.isError, isTruncated: stored.isTruncated,
                metadata: (try? JSONDecoder().decode(
                    [String: AgentJSONValue].self, from: stored.metadataData
                )) ?? [:]
            )
        }
        let review = reviews.filter { $0.invocationID == row.id }
            .sorted { $0.createdAt < $1.createdAt }
            .last.flatMap { stored -> SecurityReviewDecision? in
                guard let verdict = stored.verdict.flatMap(SecurityReviewVerdict.init),
                    let risk = stored.risk.flatMap(SecurityReviewRisk.init),
                    let authorization = stored.userAuthorization.flatMap(SecurityReviewAuthorization.init)
                else { return nil }
                return SecurityReviewDecision(
                    verdict: verdict, risk: risk, userAuthorization: authorization,
                    reason: stored.reason ?? ""
                )
            }
        return StoredAgentToolCard(
            invocation: invocation, descriptor: descriptor, state: row.state,
            result: result, review: review
        )
    }

    private func interruptUnfinishedRuns() {
        do {
            let rows = try context.fetch(FetchDescriptor<PersistentAgentRun>())
            var changed = false
            for row in rows {
                guard let state = AgentRunState(rawValue: row.state), !state.isTerminal else { continue }
                row.state = AgentRunState.interrupted.rawValue
                row.finishedAt = .now
                changed = true
            }
            if changed { try context.save() }
        } catch { context.rollback() }
    }
}

nonisolated enum AgentPersistenceRedactor {
    private static let maximumVisibleCharacters = 262_144

    static func visibleText(_ text: String) -> String {
        AgentSensitiveDataRedactor.visibleText(text, maximumCharacters: maximumVisibleCharacters)
    }

    static func redactedJSON(_ value: AgentJSONValue) -> AgentJSONValue {
        AgentSensitiveDataRedactor.redactedJSON(value)
    }

    static func encoded<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}
