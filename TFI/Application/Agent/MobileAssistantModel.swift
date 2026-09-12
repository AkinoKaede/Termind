import AgentKit
import Foundation
import Observation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure

/// Application-owned runs, with navigation and drafts independent of each run.
@MainActor
@Observable
final class MobileAssistantModel {
    let store = AssistantConversationStore()
    let library: AssistantLibraryModel
    let speech: SpeechTranscriptionCoordinator
    let configuration: AIConfigurationModel
    let skills: SkillLibraryModel
    private let authorize: @MainActor () -> Bool
    private let repository: any AgentRunPersisting
    private let operations: AssistantConversationOperations
    private let execution: AssistantExecutionController
    private let connections: AgentConnectionPool
    private let background: AgentBackgroundCommands
    private let attachmentLoader: ContextAttachmentLoading
    private var suspensionTask: Task<Void, Never>?
    private var loaded = false
    private(set) var isSuspending = false
    var error: String?

    var conversation: ConversationModel { library.selectedConversation ?? library.draftConversation }
    var isRunning: Bool { store.conversations.contains { $0.isStreaming } }

    init(
        configuration: AIConfigurationModel, repository: any AgentRunPersisting,
        hostServices: AgentHostServices, metrics: any MetricsSnapshotReading, skills: SkillLibraryModel,
        authorize: @escaping @MainActor () -> Bool,
        speech: SpeechTranscriptionCoordinator,
        attachmentLoader: ContextAttachmentLoading
    ) {
        self.authorize = authorize
        self.configuration = configuration
        self.repository = repository
        self.skills = skills
        self.speech = speech
        self.attachmentLoader = attachmentLoader
        library = AssistantLibraryModel(store: store)
        operations = AssistantConversationOperations(repository: repository)
        let resolver = hostServices.resolver
        let connections = hostServices.connections
        let authentication = hostServices.authentication
        let background = hostServices.background
        self.connections = connections
        self.background = background
        let titles = ConversationTitleController(ai: configuration)
        execution = AssistantExecutionController(
            ai: configuration, skills: skills, repository: repository,
            authorize: authorize,
            makeRegistry: { conversation, model, provider, catalog, channel, _ in
                AssistantToolRegistry.make(
                    conversation: conversation, model: model, provider: provider,
                    skills: catalog, channel: channel, ai: configuration, hosts: resolver, metrics: metrics,
                    connections: connections, authentication: authentication, background: background)
            }, title: { try await titles.summarize($0) })
        configure(conversation)
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        do {
            library.restore(try await repository.loadConversations())
            store.conversations.forEach(configure)
        } catch {
            loaded = false
            self.error = error.localizedDescription
        }
    }

    private func configure(_ conversation: ConversationModel) { conversation.attachmentLoader = attachmentLoader }

    func select(_ conversation: ConversationModel) {
        speech.cancelAll()
        library.select(conversation.id)
        configure(conversation)
    }

    func newConversation() {
        speech.cancelAll()
        _ = library.resetDraftConversation()
        configure(conversation)
    }

    func send() {
        let conversation = conversation
        guard !isSuspending, !conversation.isArchived, !conversation.isHistoryChanging,
            !conversation.isCompacting, conversation.composer.pendingAttachments.isEmpty, authorize()
        else { return }
        if conversation.isStreaming {
            conversation.submitSteeringDraft()
            return
        }
        guard conversation.canSendDraft else { return }
        if library.selectedConversation == nil {
            guard let started = library.startDraftConversation() else { return }
            configure(library.draftConversation)
            execution.startAgentRun(started)
        } else {
            execution.sendAgentDraft(conversation)
        }
    }

    func suspendRecording() { speech.cancelAll() }

    func expireBackground() {
        guard !isSuspending else { return }
        isSuspending = true
        execution.cancelPendingRuns()
        speech.cancelAll()
        let conversations = store.conversations
        suspensionTask = Task {
            for conversation in conversations { await conversation.stopAndWait() }
            await background.closeAll()
            await connections.closeAll()
            isSuspending = false
            suspensionTask = nil
        }
    }

    func waitForSuspension() async { await suspensionTask?.value }

    func selectModel(_ value: AIModelRef) {
        guard let resolved = configuration.lookup(value) else { return }
        conversation.model = value
        configuration.select(value)
        conversation.reasoningEffort = ModelCapabilityResolver.reasoning(
            model: resolved.model, provider: resolved.provider
        ).clamp(conversation.reasoningEffort)
    }

    func archive(_ conversation: ConversationModel, archived: Bool) async {
        await perform {
            try await operations.setArchived(archived, conversation: conversation)
            if archived && conversation.isArchived && self.conversation.id == conversation.id { newConversation() }
        }
    }

    func rename(_ conversation: ConversationModel, title: String) async {
        await perform { try await operations.rename(conversation, title: title) }
    }

    func move(_ conversation: ConversationModel, pinned: Bool, before: UUID? = nil) async {
        await perform { try await operations.move(conversation, pinned: pinned, before: before, library: library) }
    }

    func delete(_ conversation: ConversationModel) async {
        guard !conversation.isStreaming, !conversation.isCompacting else { return }
        await perform {
            let result = try await operations.delete(conversation)
            guard result.deleted else { return }
            library.delete(conversation.id)
            if library.selectedConversation == nil { _ = library.resetDraftConversation() }
            configure(self.conversation)
            if let cleanupError = result.cleanupError { error = cleanupError }
        }
    }

    func fork(_ conversation: ConversationModel, at messageID: UUID) async {
        await perform {
            if let fork = try await operations.fork(
                conversation, at: messageID, title: store.nextForkTitle(for: conversation))
            {
                configure(fork)
                library.insertAndSelect(fork)
            }
        }
    }

    func edit(_ conversation: ConversationModel, messageID: UUID, text: String) async {
        await perform {
            guard let prompt = try await operations.edit(conversation, messageID: messageID, text: text) else { return }
            execution.startAgentRun(
                conversation, promptID: prompt.id, prompt: prompt.text,
                authoredPrompt: prompt.authoredText, promptImages: prompt.images,
                promptContextAttachments: prompt.contextAttachments)
        }
    }

    func compact(_ conversation: ConversationModel, instructions: String = "") async {
        _ = await execution.compact(conversation, instructions: instructions)
    }

    func implement(_ card: AgentPlanCard, in conversation: ConversationModel) {
        guard !conversation.isArchived, !conversation.isStreaming else { return }
        conversation.resolvePlan(card.id, as: .implemented)
        conversation.isPlanning = false
        conversation.composer.draft = String(localized: "Implement this plan.")
        select(conversation)
        send()
    }

    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation() } catch { self.error = error.localizedDescription }
    }
}
