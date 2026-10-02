import Foundation
import TermindDomain

public nonisolated enum AssistantNotificationKind: Hashable, Sendable {
    case completed, failed, questions, secret, approval, authentication, passphrase, hostKey, mcpAuthorization
}

public nonisolated struct AssistantNotificationInteraction: Equatable, Sendable {
    public let id: UUID
    public let kind: AssistantNotificationKind

    public init(id: UUID, kind: AssistantNotificationKind) {
        self.id = id
        self.kind = kind
    }
}

public nonisolated enum AssistantNotificationEvent: Sendable {
    case finished(runID: UUID, kind: AssistantNotificationKind)
    case interactionChanged(AssistantNotificationInteraction?)
    case removed
}

extension ConversationModel {
    /// Mirrors the transcript's interaction priority, without exposing prompt or credential data.
    public var notificationInteraction: AssistantNotificationInteraction? {
        guard !runState.isTerminal, !isArchived else { return nil }
        if let interaction = pendingUserInteraction {
            switch interaction {
            case .mcpAuthorization(let prompt):
                return .init(id: prompt.id, kind: .mcpAuthorization)
            case .questions(let request):
                let secret = request.questions.contains { if case .secret = $0.kind { true } else { false } }
                return .init(id: request.id, kind: secret ? .secret : .questions)
            case .sshAuthentication(let request):
                if request.keyboardInteractive?.isInformational == true { return nil }
                return .init(id: request.id, kind: request.requiresPassphrase ? .passphrase : .authentication)
            case .sshHostKey(let request):
                return .init(id: request.id, kind: .hostKey)
            }
        }
        return pendingApproval.map { .init(id: $0.id, kind: .approval) }
    }
}

/// App-owned, independent of view mounting, title generation and Memory callbacks.
@MainActor
public final class AssistantNotificationCoordinator {
    private let service: any NotificationSending
    private let preferences: @MainActor () -> NotificationPreferences
    private let isFocused: @MainActor (UUID) -> Bool
    private let isVisible: @MainActor (UUID) -> Bool
    private let content:
        @MainActor (ConversationModel, AssistantNotificationKind, UUID?) -> (title: String, body: String)
    private struct Observation {
        weak var conversation: ConversationModel?
        var seen = Set<String>()
    }
    private var observations: [UUID: Observation] = [:]
    private var stopped = false
    private var interactionIDs: [UUID: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(
        service: any NotificationSending,
        preferences: @escaping @MainActor () -> NotificationPreferences,
        isFocused: @escaping @MainActor (UUID) -> Bool,
        isVisible: (@MainActor (UUID) -> Bool)? = nil,
        content:
            @escaping @MainActor (ConversationModel, AssistantNotificationKind, UUID?) -> (title: String, body: String)
    ) {
        self.service = service
        self.preferences = preferences
        self.isFocused = isFocused
        self.isVisible = isVisible ?? isFocused
        self.content = content
    }

    public func observe(_ conversation: ConversationModel) {
        guard !stopped else { return }
        for id in observations.keys.filter({ observations[$0]?.conversation == nil }) { unobserve(id) }
        if observations[conversation.id]?.conversation !== conversation {
            unobserve(conversation.id)
            observations[conversation.id] = Observation(conversation: conversation)
        }
        conversation.notificationEvent = { [weak self, weak conversation] event in
            guard let self, let conversation else { return }
            receive(event, from: conversation)
        }
    }

    public func unobserve(_ id: UUID) {
        guard let observation = observations.removeValue(forKey: id) else { return }
        observation.conversation?.notificationEvent = nil
        for identifier in observation.seen { tasks.removeValue(forKey: identifier)?.cancel() }
        if let interaction = interactionIDs.removeValue(forKey: id) { service.remove([interaction]) }
    }

    public func stop() {
        stopped = true
        for id in Array(observations.keys) { unobserve(id) }
    }

    private func receive(_ event: AssistantNotificationEvent, from conversation: ConversationModel) {
        guard !stopped else { return }
        let identifier: String
        let kind: AssistantNotificationKind
        let requestID: UUID?
        let completedRunID: UUID?
        switch event {
        case .removed:
            unobserve(conversation.id)
            return
        case .finished(let runID, let outcome):
            guard outcome == .completed || outcome == .failed else { return }
            identifier = "assistant.\(conversation.id).run.\(runID)"
            kind = outcome
            requestID = nil
            completedRunID = runID
        case .interactionChanged(let interaction):
            let nextID = interaction.map { "assistant.\(conversation.id).interaction.\($0.id)" }
            if let previous = interactionIDs[conversation.id], previous != nextID {
                tasks.removeValue(forKey: previous)?.cancel()
                service.remove([previous])
                conversation.removeUnreadNotification(previous)
            }
            interactionIDs[conversation.id] = nextID
            guard let interaction, let nextID else { return }
            identifier = nextID
            kind = interaction.kind
            requestID = interaction.id
            completedRunID = nil
        }
        // Suppressed events are also consumed: changing focus/settings never replays them.
        guard observations[conversation.id]?.seen.insert(identifier).inserted == true else { return }
        if !isVisible(conversation.id) { conversation.markNotificationUnread(identifier) }
        guard preferences().allowsAssistant(isFocused: isFocused(conversation.id)) else { return }
        let text = content(conversation, kind, completedRunID)
        let notification = AppNotification(
            id: identifier, target: .assistant(conversation.id), title: text.title, body: text.body)
        tasks[identifier] = Task { [weak self, weak conversation] in
            guard let self else { return }
            defer { tasks[identifier] = nil }
            await service.send(notification) { [weak self, weak conversation] in
                guard let self, !stopped, let conversation,
                    observations[conversation.id]?.conversation === conversation,
                    self.preferences().allowsAssistant(isFocused: self.isFocused(conversation.id))
                else { return false }
                return requestID == nil || conversation.notificationInteraction?.id == requestID
            }
        }
    }
}
