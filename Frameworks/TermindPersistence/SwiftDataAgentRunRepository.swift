import AgentKit
import Foundation
import SwiftData

@MainActor
public final class SwiftDataAgentRunRepository: AgentRunPersisting, Sendable {
    private let context: ModelContext
    private var deletedConversationIDs = Set<UUID>()
    private var deletedRunIDs = Set<UUID>()

    public init(context: ModelContext) {
        self.context = context
        interruptUnfinishedRuns()
    }

    @MainActor
    public func save(_ snapshot: AgentRunSnapshot) async throws {
        guard !deletedConversationIDs.contains(snapshot.conversationID) else {
            deletedRunIDs.insert(snapshot.id)
            return
        }
        let runID = snapshot.id
        let runDescriptor = FetchDescriptor<PersistentAgentRun>(predicate: #Predicate { $0.id == runID })
        if let row = try context.fetch(runDescriptor).first {
            row.update(snapshot)
        } else {
            context.insert(PersistentAgentRun(snapshot))
        }

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
            context.insert(
                PersistentAgentConversation(
                    id: conversationID, title: "", createdAt: snapshot.startedAt
                ))
        }

        // Matched on message id, not on this run's id. A conversation's earlier
        // turns are replayed into every later run, so filtering by `runID` made
        // each save re-insert the whole history — colliding with the unique
        // constraint and rewriting rows that were already correct.
        let durableMessages = snapshot.messages.filter { !$0.isCompaction }
        let ids = Set(durableMessages.map(\.id))
        let stored = try context.fetch(
            FetchDescriptor<PersistentAgentMessage>(
                predicate: #Predicate { ids.contains($0.id) }
            ))
        let storedIDs = Set(stored.map(\.id))
        var inserted = false
        for (sequence, message) in durableMessages.enumerated()
        where !storedIDs.contains(message.id) {
            context.insert(
                PersistentAgentMessage(
                    message, runID: runID, sequence: sequence
                ))
            insertContextAttachments(for: message)
            inserted = true
        }
        // A user row may already exist (editing or interrupted preparation) before
        // the run freezes its context. Add its backing once without rewriting history.
        let replayIDs = Set(try context.fetch(FetchDescriptor<PersistentAgentMessageReplay>()).map(\.messageID))
        for message in durableMessages where !replayIDs.contains(message.id) {
            insertReplay(for: message)
        }
        guard inserted || context.hasChanges else { return }
        try context.save()
    }

    @MainActor
    public func persistCompaction(
        _ record: AgentCompactionRecord, conversationID: UUID
    ) async throws {
        guard !deletedConversationIDs.contains(conversationID) else {
            throw AgentConversationPersistenceError.conversationNotFound
        }
        let conversations = try context.fetch(
            FetchDescriptor<PersistentAgentConversation>(
                predicate: #Predicate { $0.id == conversationID }
            ))
        guard conversations.first != nil else {
            throw AgentConversationPersistenceError.conversationNotFound
        }
        if let boundary = record.compactedThroughMessageID {
            let runIDs = Set(
                try context.fetch(FetchDescriptor<PersistentAgentRun>())
                    .filter { $0.conversationID == conversationID }.map(\.id))
            let rows = try context.fetch(
                FetchDescriptor<PersistentAgentMessage>(
                    predicate: #Predicate { $0.id == boundary }
                ))
            guard rows.contains(where: { runIDs.contains($0.runID) }) else {
                throw AgentConversationPersistenceError.messageNotFound
            }
        }
        let recordID = record.id
        let existing = try context.fetch(
            FetchDescriptor<PersistentAgentCompaction>(
                predicate: #Predicate { $0.id == recordID }
            ))
        guard existing.isEmpty else { return }
        context.insert(PersistentAgentCompaction(record, conversationID: conversationID))
        try context.savePendingChanges()
    }

    @MainActor
    public func record(_ event: AgentEvent, runID: UUID) async throws {
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
            context.insert(
                PersistentAgentReviewRecord(
                    runID: runID, invocationID: request.invocation.id, decision: nil
                ))
        case .reviewFinished(let request, let decision):
            context.insert(
                PersistentAgentReviewRecord(
                    runID: runID, invocationID: request.invocation.id, decision: decision
                ))
        case .reviewFailed(let request, let reason, let timedOut):
            context.insert(
                PersistentAgentReviewRecord(
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
    public func loadConversations() async throws -> [StoredAgentConversation] {
        let conversations = try context.fetch(
            FetchDescriptor<PersistentAgentConversation>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            ))
        let orderRows = try context.fetch(FetchDescriptor<PersistentAgentConversationOrder>())
        let sortIndexByConversation = Dictionary(
            uniqueKeysWithValues: orderRows.map { ($0.conversationID, $0.sortIndex) }
        )
        let runs = try context.fetch(FetchDescriptor<PersistentAgentRun>())
        let messages = try context.fetch(FetchDescriptor<PersistentAgentMessage>())
        let replayByMessage = Dictionary(
            uniqueKeysWithValues:
                try context.fetch(FetchDescriptor<PersistentAgentMessageReplay>()).map { ($0.messageID, $0) })
        let compactionRows = try context.fetch(FetchDescriptor<PersistentAgentCompaction>())
        let attachmentRows = try context.fetch(
            FetchDescriptor<PersistentAgentContextAttachments>()
        )
        let attachmentsByMessage = Dictionary(
            uniqueKeysWithValues: attachmentRows.map { ($0.messageID, $0.attachments) }
        )
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
                    if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                    // Transcript grammar gives equal-position, equal-time rows
                    // a stable and useful final ordering.
                    let rank = { (role: String) -> Int in
                        switch AgentTranscriptRole(rawValue: role) {
                        case .user: 0
                        case .assistant: 1
                        case .tool: 2
                        case nil: 3
                        }
                    }
                    return rank(lhs.role) < rank(rhs.role)
                }
                .compactMap { row -> AgentTranscriptMessage? in
                    guard let role = AgentTranscriptRole(rawValue: row.role) else { return nil }
                    let calls =
                        (try? JSONDecoder().decode(
                            [AgentToolCall].self, from: row.toolCallsData
                        )) ?? []
                    let images =
                        (try? JSONDecoder().decode(
                            [AgentImageAttachment].self, from: row.imagesData
                        )) ?? []
                    let contextAttachments = attachmentsByMessage[row.id] ?? []
                    let reasoning =
                        (try? JSONDecoder().decode(
                            [AgentReasoningBlock].self, from: row.reasoningData
                        )) ?? []
                    return AgentTranscriptMessage(
                        id: row.id, role: role, text: row.text,
                        authoredText: row.authoredText, images: images,
                        contextAttachments: contextAttachments,
                        reasoning: reasoning,
                        toolCalls: calls,
                        toolCallID: row.toolCallID, toolName: row.toolName,
                        isError: row.isError, isCompaction: row.isCompaction,
                        contextSnapshot: replayByMessage[row.id]?.contextSnapshot,
                        modelText: replayByMessage[row.id]?.modelText,
                        createdAt: row.createdAt
                    )
                }
            let messageRunIDs = Dictionary(
                uniqueKeysWithValues: messages.filter { runIDs.contains($0.runID) }
                    .map { ($0.id, $0.runID) }
            )
            let state =
                matchingRuns.last.flatMap { AgentRunState(rawValue: $0.state) }
                ?? .completed
            let cards = invocations.filter { runIDs.contains($0.runID) }
                .sorted { $0.createdAt < $1.createdAt }
                .compactMap { storedToolCard($0, results: results, reviews: reviews) }
            let projection = AgentCompactionProjection.restore(
                messages: Self.recovering(
                    transcript,
                    results: results.filter { runIDs.contains($0.runID) },
                    invocations: invocations.filter { runIDs.contains($0.runID) }
                ),
                records: compactionRows.filter { $0.conversationID == conversation.id }
                    .map(\.value)
            )
            return StoredAgentConversation(
                id: conversation.id,
                messages: projection.messages,
                modelTranscript: projection.modelTranscript,
                compactions: projection.records,
                messageRunIDs: messageRunIDs,
                runs: matchingRuns.compactMap { run in
                    guard let state = AgentRunState(rawValue: run.state) else { return nil }
                    return AgentRunSummary(
                        id: run.id, state: state, startedAt: run.startedAt,
                        finishedAt: run.finishedAt
                    )
                },
                toolCards: cards,
                lastRunState: state, title: conversation.title,
                metadata: StoredAgentConversationMetadata(
                    customTitle: conversation.customTitle,
                    isPinned: conversation.isPinned,
                    sortIndex: sortIndexByConversation[conversation.id],
                    archivedAt: conversation.archivedAt,
                    createdAt: conversation.createdAt,
                    updatedAt: conversation.updatedAt
                )
            )
        }
    }

    @MainActor
    public func setTitle(_ title: String, conversationID: UUID) async throws {
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
    public func setConversationMetadata(
        _ metadata: StoredAgentConversationMetadata, conversationID: UUID
    ) async throws {
        guard !deletedConversationIDs.contains(conversationID) else {
            throw AgentConversationPersistenceError.conversationNotFound
        }
        let descriptor = FetchDescriptor<PersistentAgentConversation>(
            predicate: #Predicate { $0.id == conversationID }
        )
        guard let row = try context.fetch(descriptor).first else {
            throw AgentConversationPersistenceError.conversationNotFound
        }
        row.customTitle = AgentPersistenceRedactor.visibleText(
            String(metadata.customTitle.prefix(80))
        )
        row.isPinned = metadata.isPinned
        row.archivedAt = metadata.archivedAt
        row.updatedAt = metadata.updatedAt
        try context.savePendingChanges()
    }

    @MainActor
    public func reorderConversations(_ updates: [StoredAgentConversationOrder]) async throws {
        let ids = Set(updates.map(\.id))
        guard updates.count == ids.count else {
            throw AgentConversationPersistenceError.conversationNotFound
        }
        let rows = try context.fetch(
            FetchDescriptor<PersistentAgentConversation>(
                predicate: #Predicate { ids.contains($0.id) }
            ))
        guard rows.count == ids.count else {
            throw AgentConversationPersistenceError.conversationNotFound
        }
        let updatesByID = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0) })
        let orderRows = try context.fetch(
            FetchDescriptor<PersistentAgentConversationOrder>(
                predicate: #Predicate { ids.contains($0.conversationID) }
            ))
        var orderByID = Dictionary(
            uniqueKeysWithValues: orderRows.map { ($0.conversationID, $0) }
        )
        for row in rows {
            guard let update = updatesByID[row.id] else { continue }
            row.isPinned = update.isPinned
            if let order = orderByID[row.id] {
                order.sortIndex = update.sortIndex
            } else {
                let order = PersistentAgentConversationOrder(
                    conversationID: row.id, sortIndex: update.sortIndex
                )
                context.insert(order)
                orderByID[row.id] = order
            }
        }
        try context.savePendingChanges()
    }

    @MainActor
    public func truncateConversation(
        _ id: UUID, fromUserMessageID messageID: UUID,
        replacingWith replacement: AgentTranscriptMessage
    ) async throws {
        let allRuns = try context.fetch(FetchDescriptor<PersistentAgentRun>())
        let runs = allRuns.filter { $0.conversationID == id }
            .sorted { $0.startedAt < $1.startedAt }
        let allMessages = try context.fetch(FetchDescriptor<PersistentAgentMessage>())
        guard
            let target = allMessages.first(where: { message in
                message.id == messageID && runs.contains { $0.id == message.runID }
            }),
            let targetIndex = runs.firstIndex(where: { $0.id == target.runID })
        else { throw AgentConversationPersistenceError.messageNotFound }

        let removedRuns = Array(runs[targetIndex...])
        let removedRunIDs = Set(removedRuns.map(\.id))
        let removedMessageIDs = Set(allMessages.filter { removedRunIDs.contains($0.runID) }.map(\.id))
        deletedRunIDs.formUnion(removedRunIDs)
        let earlierRunIDs = Set(runs[..<targetIndex].map(\.id))
        let removesOpeningTurn = !allMessages.contains {
            earlierRunIDs.contains($0.runID) && $0.role == AgentTranscriptRole.user.rawValue
                && !$0.isCompaction
        }
        do {
            try deleteGraph(runIDs: removedRunIDs, runs: removedRuns)
            for row in try context.fetch(FetchDescriptor<PersistentAgentCompaction>())
            where row.conversationID == id
                && row.compactedThroughMessageID.map(removedMessageIDs.contains) == true
            {
                context.delete(row)
            }

            let replacementRun = AgentRunSnapshot(
                conversationID: id, state: .completed,
                permissionMode: .askForApproval, messages: [replacement],
                startedAt: replacement.createdAt, finishedAt: replacement.createdAt
            )
            context.insert(PersistentAgentRun(replacementRun))
            context.insert(
                PersistentAgentMessage(
                    replacement, runID: replacementRun.id, sequence: 0
                ))
            insertContextAttachments(for: replacement)
            insertReplay(for: replacement)

            let descriptor = FetchDescriptor<PersistentAgentConversation>(
                predicate: #Predicate { $0.id == id }
            )
            if let conversation = try context.fetch(descriptor).first {
                if removesOpeningTurn { conversation.title = "" }
                conversation.updatedAt = .now
            }
            try context.save()
        } catch {
            context.rollback()
            deletedRunIDs.subtract(removedRunIDs)
            throw error
        }
    }

    @MainActor
    public func createConversation(_ value: StoredAgentConversation) async throws {
        guard !deletedConversationIDs.contains(value.id) else {
            throw AgentConversationPersistenceError.conversationAlreadyExists
        }
        let conversationID = value.id
        let descriptor = FetchDescriptor<PersistentAgentConversation>(
            predicate: #Predicate { $0.id == conversationID }
        )
        guard try context.fetch(descriptor).isEmpty else {
            throw AgentConversationPersistenceError.conversationAlreadyExists
        }

        let metadata = value.metadata
        let conversation = PersistentAgentConversation(
            id: value.id, title: value.title,
            createdAt: metadata.createdAt, updatedAt: metadata.updatedAt
        )
        conversation.customTitle = metadata.customTitle
        conversation.isPinned = metadata.isPinned
        conversation.archivedAt = metadata.archivedAt
        try context.commit {
            context.insert(conversation)
            if let sortIndex = metadata.sortIndex {
                context.insert(
                    PersistentAgentConversationOrder(
                        conversationID: value.id, sortIndex: sortIndex
                    ))
            }

            let summaries =
                value.runs.isEmpty
                ? [
                    AgentRunSummary(
                        id: UUID(), state: value.lastRunState,
                        startedAt: metadata.createdAt, finishedAt: metadata.updatedAt
                    )
                ]
                : value.runs.sorted { $0.startedAt < $1.startedAt }
            for summary in summaries {
                context.insert(
                    PersistentAgentRun(
                        AgentRunSnapshot(
                            id: summary.id, conversationID: value.id, state: summary.state,
                            permissionMode: .askForApproval, messages: [],
                            startedAt: summary.startedAt, finishedAt: summary.finishedAt
                        )))
            }
            let validRunIDs = Set(summaries.map(\.id))
            let fallbackRunID = summaries[0].id
            for (sequence, message) in value.messages.enumerated() {
                guard !message.isCompaction else { continue }
                context.insert(
                    PersistentAgentMessage(
                        message,
                        runID: value.messageRunIDs[message.id].flatMap {
                            validRunIDs.contains($0) ? $0 : nil
                        } ?? fallbackRunID,
                        sequence: sequence
                    ))
                insertContextAttachments(for: message)
                insertReplay(for: message)
            }
            for record in value.compactions {
                context.insert(PersistentAgentCompaction(record, conversationID: value.id))
            }
            for card in value.toolCards {
                var invocation = card.invocation
                if !validRunIDs.contains(invocation.runID) {
                    invocation.runID = fallbackRunID
                }
                context.insert(PersistentAgentToolInvocation(invocation, state: card.state))
                if let result = card.result {
                    context.insert(PersistentAgentToolResult(result, invocation: invocation))
                }
                if let review = card.review {
                    context.insert(
                        PersistentAgentReviewRecord(
                            runID: invocation.runID, invocationID: invocation.id, decision: review
                        ))
                }
            }
        }
    }

    @MainActor
    public func deleteConversation(_ id: UUID) async throws {
        deletedConversationIDs.insert(id)
        let runs = try context.fetch(FetchDescriptor<PersistentAgentRun>())
            .filter { $0.conversationID == id }
        let runIDs = Set(runs.map(\.id))
        deletedRunIDs.formUnion(runIDs)

        try deleteGraph(runIDs: runIDs, runs: runs)

        let conversations = try context.fetch(FetchDescriptor<PersistentAgentConversation>())
        for row in conversations where row.id == id { context.delete(row) }
        let orderRows = try context.fetch(FetchDescriptor<PersistentAgentConversationOrder>())
        for row in orderRows where row.conversationID == id { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<PersistentAgentCompaction>())
        where row.conversationID == id { context.delete(row) }
        try context.save()
    }

    private func deleteGraph(runIDs: Set<UUID>, runs: [PersistentAgentRun]) throws {
        for row in try context.fetch(FetchDescriptor<PersistentAgentToolResult>())
        where runIDs.contains(row.runID) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<PersistentAgentReviewRecord>())
        where runIDs.contains(row.runID) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<PersistentAgentToolInvocation>())
        where runIDs.contains(row.runID) { context.delete(row) }
        let messages = try context.fetch(FetchDescriptor<PersistentAgentMessage>())
            .filter { runIDs.contains($0.runID) }
        let messageIDs = Set(messages.map(\.id))
        for row in try context.fetch(FetchDescriptor<PersistentAgentContextAttachments>())
        where messageIDs.contains(row.messageID) { context.delete(row) }
        for row in try context.fetch(FetchDescriptor<PersistentAgentMessageReplay>())
        where messageIDs.contains(row.messageID) { context.delete(row) }
        for row in messages { context.delete(row) }
        for row in runs { context.delete(row) }
    }

    private func insertReplay(for message: AgentTranscriptMessage) {
        guard message.contextSnapshot != nil || message.modelText != nil else { return }
        context.insert(PersistentAgentMessageReplay(message))
    }

    private func insertContextAttachments(for message: AgentTranscriptMessage) {
        guard !message.contextAttachments.isEmpty else { return }
        context.insert(
            PersistentAgentContextAttachments(
                messageID: message.id, attachments: message.contextAttachments
            ))
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
    public static func recovering(
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
                recovered.append(
                    AgentTranscriptMessage(
                        id: AgentTranscriptMessage.toolResultID(runID: stored.runID, callID: call.id),
                        role: .tool, text: stored.content, toolCallID: call.id,
                        toolName: names[call.id] ?? call.name, isError: stored.isError,
                        modelText: (try? JSONDecoder().decode([String: AgentJSONValue].self, from: stored.metadataData))?[
                            AgentToolResult.modelContentKey]?.stringValue
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
            if row.sourceMessageID == nil { row.sourceMessageID = invocation.sourceMessageID }
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
            sourceMessageID: row.sourceMessageID,
            targetHostID: row.targetHostID, createdAt: row.createdAt
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
        let descriptor = AgentToolDescriptor(
            name: row.toolName, summary: row.toolName,
            inputSchema: .object(["type": .string("object")]),
            target: row.targetHostID == nil ? .local : .host,
            approvalPolicy: .ask, presentation: result?.toolPresentation
        )
        let review = reviews.filter { $0.invocationID == row.id }
            .sorted { $0.createdAt < $1.createdAt }
            .last.flatMap { stored -> GuardianDecision? in
                guard let verdict = stored.verdict.flatMap(GuardianVerdict.init),
                    let risk = stored.risk.flatMap(GuardianRisk.init),
                    let authorization = stored.userAuthorization.flatMap({ raw in
                        GuardianAuthorization(rawValue: raw)
                            ?? (raw == "sufficient" ? .high : raw == "insufficient" ? .low : nil)
                    })
                else { return nil }
                return GuardianDecision(
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
