import AgentKit
import Foundation
import TermindDomain

nonisolated public struct AssistantChatCreationRelation: Hashable, Sendable {
    public init(
        conversationID: UUID, sourceConversationID: UUID,
        sourceRunID: UUID, sourceToolCallID: String
    ) {
        self.conversationID = conversationID
        self.sourceConversationID = sourceConversationID
        self.sourceRunID = sourceRunID
        self.sourceToolCallID = sourceToolCallID
    }

    public var conversationID: UUID
    public var sourceConversationID: UUID
    public var sourceRunID: UUID
    public var sourceToolCallID: String
}

nonisolated public struct AssistantChatDeliveryReceipt: Identifiable, Hashable, Sendable {
    public init(
        id: UUID = UUID(), sourceConversationID: UUID, targetConversationID: UUID,
        sourceRunID: UUID, sourceToolCallID: String, messageID: UUID,
        state: AgentMessageDeliveryState, createdAt: Date = .now,
        updatedAt: Date = .now, failure: String? = nil
    ) {
        self.id = id
        self.sourceConversationID = sourceConversationID
        self.targetConversationID = targetConversationID
        self.sourceRunID = sourceRunID
        self.sourceToolCallID = sourceToolCallID
        self.messageID = messageID
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.failure = failure
    }

    public var id: UUID
    public var sourceConversationID: UUID
    public var targetConversationID: UUID
    public var sourceRunID: UUID
    public var sourceToolCallID: String
    public var messageID: UUID
    public var state: AgentMessageDeliveryState
    public var createdAt: Date
    public var updatedAt: Date
    public var failure: String?
}

@MainActor public protocol AssistantChatCollaborationStoring {
    /// Whether delivery becomes durable in the same transaction that persists the
    /// origin message. Stores with this guarantee must not be marked delivered by
    /// the earlier in-memory runtime event.
    var confirmsDeliveryDuringMessagePersistence: Bool { get }
    func receipt(sourceRunID: UUID, sourceToolCallID: String) throws -> AssistantChatDeliveryReceipt?
    func save(_ receipt: AssistantChatDeliveryReceipt) throws
    func updateReceipt(
        messageID: UUID, state: AgentMessageDeliveryState, failure: String?
    ) throws
    func receipts(targetConversationID: UUID) throws -> [AssistantChatDeliveryReceipt]
    func save(_ relation: AssistantChatCreationRelation) throws
    func deleteRelation(conversationID: UUID) throws
}

@MainActor
public final class InMemoryAssistantChatCollaborationStore: AssistantChatCollaborationStoring {
    private var storedReceipts: [UUID: AssistantChatDeliveryReceipt] = [:]
    private var relations: [UUID: AssistantChatCreationRelation] = [:]

    public init() {}

    public var confirmsDeliveryDuringMessagePersistence: Bool { false }

    public func receipt(sourceRunID: UUID, sourceToolCallID: String) throws
        -> AssistantChatDeliveryReceipt?
    {
        storedReceipts.values.first {
            $0.sourceRunID == sourceRunID && $0.sourceToolCallID == sourceToolCallID
        }
    }

    public func save(_ receipt: AssistantChatDeliveryReceipt) throws {
        if let existing = try self.receipt(
            sourceRunID: receipt.sourceRunID, sourceToolCallID: receipt.sourceToolCallID)
        {
            guard existing.state != .delivered || receipt.state == .delivered else { return }
            var updated = receipt
            updated.id = existing.id
            storedReceipts[existing.id] = updated
        } else {
            storedReceipts[receipt.id] = receipt
        }
    }

    public func updateReceipt(
        messageID: UUID, state: AgentMessageDeliveryState, failure: String?
    ) throws {
        guard let id = storedReceipts.first(where: { $0.value.messageID == messageID })?.key,
            var receipt = storedReceipts[id]
        else { return }
        guard receipt.state != .delivered || state == .delivered else { return }
        receipt.state = state
        receipt.failure = failure
        receipt.updatedAt = .now
        storedReceipts[id] = receipt
    }

    public func receipts(targetConversationID: UUID) throws -> [AssistantChatDeliveryReceipt] {
        storedReceipts.values.filter { $0.targetConversationID == targetConversationID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ relation: AssistantChatCreationRelation) throws {
        if relations[relation.conversationID] == nil { relations[relation.conversationID] = relation }
    }

    public func deleteRelation(conversationID: UUID) throws {
        relations[conversationID] = nil
    }
}

/// Shared local-device coordination used by both native app adapters.
@MainActor
public final class AssistantChatCoordinator: AgentChatModelCatalog, AgentChatCoordinating {
    private let conversations: AssistantConversationStore
    private let ai: AIConfigurationModel
    private let modelSelections: AssistantModelSelectionController
    private let collaborationStore: any AssistantChatCollaborationStoring
    private let prepareDelivery:
        @MainActor (String, AgentMessageOrigin, ConversationModel) -> AssistantExecutionController
            .PreparedAgentDelivery?
    private let persistDelivery:
        @MainActor (AssistantExecutionController.PreparedAgentDelivery, ConversationModel) async throws -> Void
    private let startDelivery:
        @MainActor (AssistantExecutionController.PreparedAgentDelivery, ConversationModel) -> Void
    private let cancelDelivery:
        @MainActor (AssistantExecutionController.PreparedAgentDelivery, ConversationModel) async -> Void
    private var waiters: [UUID: (ids: Set<UUID>, continuation: AsyncStream<Void>.Continuation)] = [:]

    public init(
        conversations: AssistantConversationStore,
        ai: AIConfigurationModel,
        modelSelections: AssistantModelSelectionController,
        collaborationStore: any AssistantChatCollaborationStoring,
        prepareDelivery:
            @escaping @MainActor (
                String, AgentMessageOrigin, ConversationModel
            ) -> AssistantExecutionController.PreparedAgentDelivery?,
        persistDelivery:
            @escaping @MainActor (
                AssistantExecutionController.PreparedAgentDelivery, ConversationModel
            ) async throws -> Void,
        startDelivery:
            @escaping @MainActor (
                AssistantExecutionController.PreparedAgentDelivery, ConversationModel
            ) -> Void,
        cancelDelivery:
            @escaping @MainActor (
                AssistantExecutionController.PreparedAgentDelivery, ConversationModel
            ) async -> Void
    ) {
        self.conversations = conversations
        self.ai = ai
        self.modelSelections = modelSelections
        self.collaborationStore = collaborationStore
        self.prepareDelivery = prepareDelivery
        self.persistDelivery = persistDelivery
        self.startDelivery = startDelivery
        self.cancelDelivery = cancelDelivery
    }

    public func configuredChatModels() async throws -> [AgentChatModelDescription] {
        ai.enabledModelProviders.flatMap { provider in
            provider.chatModels.map { model in
                AgentChatModelDescription(
                    reference: Self.reference(
                        AIModelRef(modelProviderID: provider.id, modelID: model.id)),
                    name: model.label, provider: provider.name,
                    abilities: model.abilities.map(\.rawValue).sorted(),
                    contextWindow: model.contextLength ?? 0,
                    supportedReasoning: ModelCapabilityResolver.reasoning(
                        model: model, provider: provider
                    ).supported.map(\.rawValue),
                    isReady: ai.modelSecret(for: provider) != nil
                        && !provider.inferenceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
    }

    public func createChat(
        prompt: String, model: String?, title: String?, source: AgentChatSourceContext,
        sourceRunID: UUID, sourceToolCallID: String
    ) async throws -> AgentJSONValue {
        if let existing = try existingDelivery(
            sourceRunID: sourceRunID, sourceToolCallID: sourceToolCallID)
        {
            return existing
        }
        let target = ConversationModel()
        target.permissionMode = source.permissionMode
        target.isPlanning = source.mode == .planning
        target.customTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty
        let selected: AIModelRef
        if let model {
            guard let explicit = Self.modelReference(model), ai.lookupChat(explicit) != nil else {
                throw AgentToolError.invalidArguments("The requested Chat model is unavailable.")
            }
            selected = explicit
        } else {
            guard let inherited = Self.modelReference(source.modelReference), ai.lookupChat(inherited) != nil else {
                throw AgentToolError.invalidArguments("The source Chat model is unavailable.")
            }
            selected = inherited
        }
        target.model = selected
        try modelSelections.prepareForSend(target)
        let origin = AgentMessageOrigin(
            sourceConversationID: source.conversationID, sourceRunID: sourceRunID,
            sourceToolCallID: sourceToolCallID, sourceTitle: source.title)
        guard let prepared = prepareDelivery(prompt, origin, target) else {
            throw AgentToolError.invalidArguments("The new chat could not be prepared.")
        }
        let receipt = AssistantChatDeliveryReceipt(
            sourceConversationID: source.conversationID, targetConversationID: target.id,
            sourceRunID: sourceRunID, sourceToolCallID: sourceToolCallID,
            messageID: prepared.message.id, state: .queued)
        do {
            try collaborationStore.save(
                AssistantChatCreationRelation(
                    conversationID: target.id, sourceConversationID: source.conversationID,
                    sourceRunID: sourceRunID, sourceToolCallID: sourceToolCallID))
            try collaborationStore.save(receipt)
            try await persistDelivery(prepared, target)
        } catch {
            await cancelDelivery(prepared, target)
            try? collaborationStore.updateReceipt(
                messageID: prepared.message.id, state: .undelivered,
                failure: error.localizedDescription)
            try? collaborationStore.deleteRelation(conversationID: target.id)
            throw error
        }
        try? collaborationStore.updateReceipt(
            messageID: prepared.message.id, state: .delivered, failure: nil)
        configure(target)
        conversations.insert(target)
        startDelivery(prepared, target)
        return chatJSON(target, status: "accepted", receiptID: receipt.id)
    }

    public func listChats(cursor: String?, includeArchived: Bool) async throws -> AgentJSONValue {
        attachAll()
        let offset = try Self.offset(cursor)
        let candidates = conversations.conversations
            .filter { includeArchived || !$0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard offset <= candidates.count else {
            throw AgentToolError.invalidArguments("The chat cursor is invalid.")
        }
        let page = Array(candidates.dropFirst(offset).prefix(20))
        var result: [String: AgentJSONValue] = [
            "chats": .array(page.map { chatJSON($0) }),
            "count": .number(Double(page.count)),
        ]
        let next = offset + page.count
        if next < candidates.count { result["next_cursor"] = .string(String(next)) }
        return .object(result)
    }

    public func readChat(id: UUID, cursor: String?) async throws -> AgentJSONValue {
        guard let conversation = conversations.conversation(id: id) else {
            throw AgentToolError.invalidArguments("The chat does not exist.")
        }
        configure(conversation)
        let offset = try Self.offset(cursor)
        let visible = conversation.messages
        guard offset <= visible.count else {
            throw AgentToolError.invalidArguments("The chat cursor is invalid.")
        }
        let page = Array(visible.dropFirst(offset).prefix(20))
        var budget = 40_000
        var wasTruncated = false
        let messages = page.map { message -> AgentJSONValue in
            let allowed = max(0, min(8_000, budget))
            let text = String(message.text.prefix(allowed))
            if text.count < message.text.count { wasTruncated = true }
            budget -= text.count
            return .object([
                "role": .string(message.role == .user ? "user" : "assistant"),
                "text": .string(text),
                "agent_origin": .bool(message.origin != nil),
            ])
        }
        let toolRows = conversation.toolCards.suffix(20).map { card in
            AgentJSONValue.object([
                "name": .string(card.descriptor.name),
                "state": .string(card.state.rawValue),
            ])
        }
        let receipts = (try? collaborationStore.receipts(targetConversationID: id)) ?? []
        var result = chatObject(conversation)
        result["messages"] = .array(messages)
        result["message_count"] = .number(Double(page.count))
        result["tool_summaries"] = .array(toolRows)
        result["deliveries"] = .array(receipts.suffix(20).map(receiptJSON))
        result["truncated"] = .bool(wasTruncated)
        let next = offset + page.count
        if next < visible.count { result["next_cursor"] = .string(String(next)) }
        return .object(result)
    }

    public func sendToChat(
        id: UUID, message: String, source: AgentChatSourceContext,
        sourceRunID: UUID, sourceToolCallID: String
    ) async throws -> AgentJSONValue {
        if let existing = try existingDelivery(
            sourceRunID: sourceRunID, sourceToolCallID: sourceToolCallID)
        {
            return existing
        }
        guard id != source.conversationID else {
            throw AgentToolError.invalidArguments("A chat cannot send a message to itself.")
        }
        guard let target = conversations.conversation(id: id), !target.isArchived else {
            throw AgentToolError.invalidArguments("The target chat is unavailable.")
        }
        guard !target.isCompacting, !target.isHistoryChanging, !target.isPreparingAgentRun else {
            throw AgentToolError.invalidArguments("The target chat is busy changing history.")
        }
        if source.mode == .planning, !target.effectiveIsPlanning {
            throw AgentToolError.invalidArguments("Plan mode can send only to another chat in Plan mode.")
        }
        configure(target)
        let origin = AgentMessageOrigin(
            sourceConversationID: source.conversationID, sourceRunID: sourceRunID,
            sourceToolCallID: sourceToolCallID, sourceTitle: source.title)
        let incoming = AgentTranscriptMessage(
            role: .user, text: message, authoredText: nil, origin: origin)
        if target.isStreaming {
            var receipt = AssistantChatDeliveryReceipt(
                sourceConversationID: source.conversationID, targetConversationID: target.id,
                sourceRunID: sourceRunID, sourceToolCallID: sourceToolCallID,
                messageID: incoming.id, state: .queued)
            try collaborationStore.save(receipt)
            guard target.submitIncomingAgentSteering(incoming) else {
                receipt.state = .undelivered
                receipt.failure = "The target run ended before delivery."
                receipt.updatedAt = .now
                try collaborationStore.save(receipt)
                return receiptJSON(receipt)
            }
            return chatJSON(target, status: "queued", receiptID: receipt.id)
        }
        guard let prepared = prepareDelivery(message, origin, target) else {
            throw AgentToolError.invalidArguments("The target chat could not accept the message.")
        }
        let receipt = AssistantChatDeliveryReceipt(
            sourceConversationID: source.conversationID, targetConversationID: target.id,
            sourceRunID: sourceRunID, sourceToolCallID: sourceToolCallID,
            messageID: prepared.message.id, state: .queued)
        do {
            try collaborationStore.save(receipt)
            try await persistDelivery(prepared, target)
        } catch {
            await cancelDelivery(prepared, target)
            try? collaborationStore.updateReceipt(
                messageID: prepared.message.id, state: .undelivered,
                failure: error.localizedDescription)
            throw error
        }
        try? collaborationStore.updateReceipt(
            messageID: prepared.message.id, state: .delivered, failure: nil)
        startDelivery(prepared, target)
        return chatJSON(target, status: "delivered", receiptID: receipt.id)
    }

    public func waitForChats(
        ids: [UUID], timeoutMilliseconds: Int, source: AgentChatSourceContext,
        untilUserInterjects: @escaping @concurrent @Sendable () async -> Void
    ) async throws -> AgentJSONValue {
        attachAll()
        let missing = ids.filter { conversations.conversation(id: $0) == nil }
        guard missing.isEmpty else {
            throw AgentToolError.invalidArguments(
                "One or more target chats no longer exist: \(missing.map(\.uuidString).joined(separator: ", ")).")
        }
        let ready = readyChats(ids)
        if !ready.isEmpty || timeoutMilliseconds == 0 {
            return waitJSON(ids: ids, timedOut: ready.isEmpty)
        }
        let stream = makeWaitStream(ids: Set(ids))
        let outcome = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            group.addTask {
                for await _ in stream { return 0 }
                return 0
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                return 1
            }
            group.addTask {
                await untilUserInterjects()
                return 2
            }
            let first = await group.next() ?? 1
            group.cancelAll()
            return first
        }
        return waitJSON(ids: ids, timedOut: outcome == 1, interrupted: outcome == 2)
    }

    private func configure(_ conversation: ConversationModel) {
        let conversationID = conversation.id
        conversation.chatStateDidChange = { [weak self] id in self?.signal(id) }
        conversation.agentMessageDeliveryChanged = { [weak self] message, state in
            guard let self else { return }
            if state != .delivered || !self.collaborationStore.confirmsDeliveryDuringMessagePersistence {
                try? self.collaborationStore.updateReceipt(
                    messageID: message.id, state: state,
                    failure: state == .undelivered ? "The target run ended before delivery." : nil)
            }
            self.signal(conversationID)
        }
        reconcileReceipts(for: conversation)
    }

    private func attachAll() { conversations.conversations.forEach(configure) }

    private func signal(_ id: UUID) {
        guard let conversation = conversations.conversation(id: id), isReady(conversation) else { return }
        for (_, waiter) in waiters where waiter.ids.contains(id) {
            waiter.continuation.yield()
            waiter.continuation.finish()
        }
    }

    private func makeWaitStream(ids: Set<UUID>) -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            waiters[id] = (ids, continuation)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.waiters[id] = nil }
            }
        }
    }

    private func readyChats(_ ids: [UUID]) -> [ConversationModel] {
        ids.compactMap { conversations.conversation(id: $0) }.filter(isReady)
    }

    private func isReady(_ conversation: ConversationModel) -> Bool {
        !conversation.isPreparingAgentRun
            && (conversation.runState.isTerminal || conversation.runState == .waitingForUser
                || conversation.runState == .waitingForApproval)
    }

    private func waitJSON(
        ids: [UUID], timedOut: Bool, interrupted: Bool = false
    ) -> AgentJSONValue {
        .object([
            "timed_out": .bool(timedOut),
            "interrupted": .bool(interrupted),
            "chats": .array(
                ids.compactMap { id in
                    conversations.conversation(id: id).map { chatJSON($0) }
                }),
        ])
    }

    private func chatJSON(
        _ conversation: ConversationModel, status: String? = nil, receiptID: UUID? = nil
    ) -> AgentJSONValue {
        var object = chatObject(conversation)
        if let status { object["status"] = .string(status) }
        if let receiptID { object["receipt_id"] = .string(receiptID.uuidString) }
        return .object(object)
    }

    private func chatObject(_ conversation: ConversationModel) -> [String: AgentJSONValue] {
        [
            "chat_id": .string(conversation.id.uuidString),
            "title": .string(conversation.derivedTitle),
            "model": .string(conversation.model.flatMap { ai.lookupChat($0)?.model.label } ?? ""),
            "status": .string(conversation.isPreparingAgentRun ? "preparing" : conversation.runState.rawValue),
            "updated_at": .string(conversation.updatedAt.ISO8601Format()),
            "archived": .bool(conversation.isArchived),
        ]
    }

    private func receiptJSON(_ receipt: AssistantChatDeliveryReceipt) -> AgentJSONValue {
        let title = conversations.conversation(id: receipt.targetConversationID)?.derivedTitle ?? ""
        return .object([
            "chat_id": .string(receipt.targetConversationID.uuidString),
            "title": .string(title),
            "status": .string(receipt.state.rawValue),
            "receipt_id": .string(receipt.id.uuidString),
        ])
    }

    private func existingDelivery(sourceRunID: UUID, sourceToolCallID: String) throws -> AgentJSONValue? {
        guard
            var receipt = try collaborationStore.receipt(
                sourceRunID: sourceRunID, sourceToolCallID: sourceToolCallID)
        else { return nil }
        guard let target = conversations.conversation(id: receipt.targetConversationID) else {
            if receipt.state == .queued {
                receipt.state = .undelivered
                receipt.failure = "The target chat no longer exists."
                receipt.updatedAt = .now
                try collaborationStore.save(receipt)
            }
            return receiptJSON(receipt)
        }
        configure(target)
        receipt =
            try collaborationStore.receipt(
                sourceRunID: sourceRunID, sourceToolCallID: sourceToolCallID) ?? receipt
        return chatJSON(target, status: receipt.state.rawValue, receiptID: receipt.id)
    }

    /// A queued reservation survives a crash. Once the conversation is restored,
    /// the durable prompt proves delivery; an absent prompt with no live owner proves
    /// it can no longer be delivered.
    private func reconcileReceipts(for conversation: ConversationModel) {
        guard let receipts = try? collaborationStore.receipts(targetConversationID: conversation.id) else {
            return
        }
        let messageIDs = Set(conversation.transcript.map(\.id)).union(conversation.messages.map(\.id))
        for receipt in receipts where receipt.state == .queued {
            if messageIDs.contains(receipt.messageID),
                !collaborationStore.confirmsDeliveryDuringMessagePersistence
            {
                try? collaborationStore.updateReceipt(
                    messageID: receipt.messageID, state: .delivered, failure: nil)
            } else if !conversation.isAgentRunActive {
                try? collaborationStore.updateReceipt(
                    messageID: receipt.messageID, state: .undelivered,
                    failure: "The pending delivery did not survive restart.")
            }
        }
    }

    public static func reference(_ ref: AIModelRef) -> String {
        "\(ref.modelProviderID.uuidString)::\(ref.modelID)"
    }

    private static func modelReference(_ value: String) -> AIModelRef? {
        guard let boundary = value.range(of: "::"),
            let providerID = UUID(uuidString: String(value[..<boundary.lowerBound]))
        else { return nil }
        return AIModelRef(
            modelProviderID: providerID, modelID: String(value[boundary.upperBound...]))
    }

    private static func offset(_ cursor: String?) throws -> Int {
        guard let cursor else { return 0 }
        guard let value = Int(cursor), value >= 0, value <= 10_000_000 else {
            throw AgentToolError.invalidArguments("The chat cursor is invalid.")
        }
        return value
    }
}

extension String {
    fileprivate var nonempty: String? { isEmpty ? nil : self }
}
