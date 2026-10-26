// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import Logging
import Observation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure

@MainActor
@Observable
private final class MobileAssistantSuspensionGate {
    var isSuspending = false
}

/// Application-owned Assistant runs and services. Scene-local navigation lives in
/// `MobileAssistantSceneModel`; only the conversation store is shared here.
@MainActor
@Observable
final class MobileAssistantModel {
    static let terminalSuggestionsAvailable = false

    let store = AssistantConversationStore()
    let speech: SpeechTranscriptionCoordinator
    let configuration: AIConfigurationModel
    let skills: SkillLibraryModel
    private let authorize: @MainActor () -> Bool
    private let repository: any AgentRunPersisting
    fileprivate let modelSelections: AssistantModelSelectionController
    private let operations: AssistantConversationOperations
    private let chatCoordinator: AssistantChatCoordinator
    var observeNotifications: ((ConversationModel) -> Void)? {
        didSet { execution.observeNotifications = observeNotifications }
    }
    private let execution: AssistantExecutionController
    private let connections: AgentConnectionPool
    private let background: AgentBackgroundCommands
    private let attachmentLoader: ContextAttachmentLoading
    private var loadTask: Task<Void, Never>?
    private var suspensionTask: Task<Void, Never>?
    private let suspensionGate: MobileAssistantSuspensionGate
    private var loaded = false
    var isSuspending: Bool { suspensionGate.isSuspending }
    var error: String?

    var isRunning: Bool { store.conversations.contains { $0.isStreaming } }

    func disconnectHost(_ id: UUID) {
        Task { await connections.disconnect(hostID: id) }
    }

    func makeSceneModel() -> MobileAssistantSceneModel {
        MobileAssistantSceneModel(runtime: self, library: AssistantLibraryModel(store: store))
    }

    init(
        configuration: AIConfigurationModel, repository: any AgentRunPersisting, memory: MemoryModel? = nil,
        modelSelectionStore: any AssistantModelSelectionStoring = InMemoryAssistantModelSelectionStore(),
        chatCollaborationStore: any AssistantChatCollaborationStoring = InMemoryAssistantChatCollaborationStore(),
        hostServices: AgentHostServices, metrics: any MetricsSnapshotReading, skills: SkillLibraryModel,
        authorize: @escaping @MainActor () -> Bool,
        speech: SpeechTranscriptionCoordinator,
        attachmentLoader: ContextAttachmentLoading,
        logger: Logger = ApplicationLogger.disabled("termind.agent"),
        management: AgentResourceManager? = nil
    ) {
        self.authorize = authorize
        self.configuration = configuration
        self.repository = repository
        modelSelections = AssistantModelSelectionController(ai: configuration, store: modelSelectionStore)
        self.skills = skills
        self.speech = speech
        self.attachmentLoader = attachmentLoader
        operations = AssistantConversationOperations(repository: repository, modelSelections: modelSelections)
        let resolver = hostServices.resolver
        let connections = hostServices.connections
        let authentication = hostServices.authentication
        let background = hostServices.background
        self.connections = connections
        self.background = background
        let suspensionGate = MobileAssistantSuspensionGate()
        self.suspensionGate = suspensionGate
        let titles = ConversationTitleController(ai: configuration)
        final class CoordinatorBox {
            weak var value: AssistantChatCoordinator?
        }
        let coordinatorBox = CoordinatorBox()
        execution = AssistantExecutionController(
            ai: configuration, skills: skills, repository: repository, memory: memory,
            modelSelections: modelSelections,
            authorize: authorize,
            makeRegistry: { conversation, model, provider, catalog, channel, panes, source in
                AssistantToolRegistry.make(
                    conversation: conversation, model: model, provider: provider,
                    skills: catalog, channel: channel, ai: configuration, hosts: resolver, metrics: metrics,
                    connections: connections, authentication: authentication, background: background,
                    panes: panes, chatModels: coordinatorBox.value,
                    chats: coordinatorBox.value, chatSource: source, management: management)
            }, title: { try await titles.summarize($0) }, logger: logger)
        chatCoordinator = AssistantChatCoordinator(
            conversations: store, ai: configuration, modelSelections: modelSelections,
            collaborationStore: chatCollaborationStore,
            prepareDelivery: { [weak execution, suspensionGate] text, origin, conversation in
                guard !suspensionGate.isSuspending else { return nil }
                return execution?.prepareIncomingAgentMessage(text, origin: origin, in: conversation)
            },
            persistDelivery: { [weak execution] prepared, conversation in
                guard let execution else { throw CancellationError() }
                try await execution.persistPreparedAgentDelivery(prepared, in: conversation)
            },
            startDelivery: { [weak execution] prepared, conversation in
                conversation.attachmentLoader = attachmentLoader
                execution?.observeNotifications?(conversation)
                execution?.startPreparedAgentDelivery(prepared, in: conversation)
            },
            cancelDelivery: { [weak execution] prepared, conversation in
                await execution?.cancelPreparedAgentDelivery(prepared, in: conversation)
            })
        coordinatorBox.value = chatCoordinator
        execution.reportModelSelectionError = { [weak self] message in self?.error = message }
    }

    func load() async {
        if loaded { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let loadTask = Task { [weak self] in
            guard let self else { return }
            await loadOnce()
        }
        self.loadTask = loadTask
        await loadTask.value
        self.loadTask = nil
    }

    private func loadOnce() async {
        do {
            let restored = try await repository.loadConversations()
            let selections = try modelSelections.selectionsForRestore(restored)
            store.restore(restored, modelSelections: selections)
            store.conversations.forEach(configure)
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    fileprivate func configure(_ conversation: ConversationModel) { conversation.attachmentLoader = attachmentLoader }

    fileprivate func select(_ conversation: ConversationModel, in library: AssistantLibraryModel) {
        speech.cancelAll()
        library.select(conversation.id)
        configure(conversation)
    }

    fileprivate func newConversation(in library: AssistantLibraryModel) {
        speech.cancelAll()
        _ = library.resetDraftConversation()
        configure(library.draftConversation)
    }

    fileprivate func send(in library: AssistantLibraryModel, panes: AgentPaneAccess?) {
        let conversation = library.selectedConversation ?? library.draftConversation
        guard !isSuspending, !conversation.isArchived, !conversation.isHistoryChanging,
            !conversation.isCompacting, conversation.composer.pendingAttachments.isEmpty, authorize()
        else { return }
        if conversation.isStreaming {
            conversation.submitSteeringDraft(
                terminalSuggestionsAvailable: Self.terminalSuggestionsAvailable)
            return
        }
        guard conversation.canSendDraft else { return }
        if library.selectedConversation == nil {
            guard
                execution.sendDraftConversation(
                    in: library,
                    terminalSuggestionsAvailable: Self.terminalSuggestionsAvailable, panes: panes) != nil
            else { return }
            configure(library.draftConversation)
        } else {
            execution.sendAgentDraft(
                conversation, terminalSuggestionsAvailable: Self.terminalSuggestionsAvailable, panes: panes)
        }
    }

    func suspendRecording() { speech.cancelAll() }

    func expireBackground() {
        guard !isSuspending else { return }
        suspensionGate.isSuspending = true
        execution.cancelPendingRuns()
        speech.cancelAll()
        let conversations = store.conversations
        // Request every cancellation before awaiting a drain that may be held by persistence.
        for conversation in conversations { conversation.stop() }
        suspensionTask = Task {
            for conversation in conversations { await conversation.stopAndWait() }
            await background.closeAll()
            await connections.closeAll()
            suspensionGate.isSuspending = false
            suspensionTask = nil
        }
    }

    func waitForSuspension() async { await suspensionTask?.value }

    func repairUnavailableModels() {
        do {
            try modelSelections.repairUnavailable(in: store.conversations)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    fileprivate func selectModel(_ value: AIModelRef, for conversation: ConversationModel) -> Bool {
        guard let resolved = configuration.lookup(value) else { return false }
        do {
            try modelSelections.select(value, for: conversation)
        } catch {
            self.error = error.localizedDescription
            return false
        }
        conversation.reasoningEffort = ModelCapabilityResolver.reasoning(
            model: resolved.model, provider: resolved.provider
        ).clamp(conversation.reasoningEffort)
        return true
    }

    fileprivate func archive(
        _ conversation: ConversationModel, archived: Bool, in library: AssistantLibraryModel
    ) async {
        await perform {
            try await operations.setArchived(archived, conversation: conversation)
            let selected = library.selectedConversation ?? library.draftConversation
            if archived && conversation.isArchived && selected.id == conversation.id {
                newConversation(in: library)
            }
        }
    }

    func rename(_ conversation: ConversationModel, title: String) async {
        await perform { try await operations.rename(conversation, title: title) }
    }

    fileprivate func move(
        _ conversation: ConversationModel, pinned: Bool, before: UUID? = nil,
        in library: AssistantLibraryModel
    ) async {
        await perform { try await operations.move(conversation, pinned: pinned, before: before, library: library) }
    }

    fileprivate func delete(_ conversation: ConversationModel, from library: AssistantLibraryModel) async {
        guard !conversation.isStreaming, !conversation.isCompacting else { return }
        await perform {
            let result = try await operations.delete(conversation)
            guard result.deleted else { return }
            library.delete(conversation.id)
            if library.selectedConversation == nil { _ = library.resetDraftConversation() }
            configure(library.selectedConversation ?? library.draftConversation)
            if let cleanupError = result.cleanupError { error = cleanupError }
        }
    }

    fileprivate func fork(
        _ conversation: ConversationModel, at messageID: UUID, in library: AssistantLibraryModel
    ) async {
        await perform {
            if let fork = try await operations.fork(
                conversation, at: messageID, title: store.nextForkTitle(for: conversation))
            {
                configure(fork)
                library.insertAndSelect(fork)
            }
        }
    }

    func edit(_ conversation: ConversationModel, messageID: UUID, text: String, panes: AgentPaneAccess?) {
        guard !isSuspending else { return }
        guard
            let prepared = execution.prepareAgentEdit(
                conversation, messageID: messageID, text: text,
                terminalSuggestionsAvailable: Self.terminalSuggestionsAvailable, panes: panes)
        else { return }
        Task {
            await perform {
                _ = try await execution.performAgentEdit(
                    prepared, in: conversation, operations: operations)
            }
        }
    }

    func compact(_ conversation: ConversationModel, instructions: String = "") async {
        guard !isSuspending else { return }
        _ = await execution.compact(conversation, instructions: instructions)
    }

    fileprivate func implement(
        _ card: AgentPlanCard, in conversation: ConversationModel, library: AssistantLibraryModel,
        panes: AgentPaneAccess?
    ) {
        guard !isSuspending else { return }
        guard
            execution.sendPlanImplementation(
                card, in: conversation,
                terminalSuggestionsAvailable: Self.terminalSuggestionsAvailable, panes: panes)
        else { return }
        select(conversation, in: library)
    }

    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation() } catch { self.error = error.localizedDescription }
    }
}

/// Scene-local Assistant navigation over the app-wide conversation store and run services.
///
/// The runtime owns work that must survive navigation. The library owns only the selected
/// conversation and the New Chat draft, so two iPad windows can navigate independently
/// without duplicating a running conversation.
@MainActor
@Observable
final class MobileAssistantSceneModel {
    private let runtime: MobileAssistantModel
    let library: AssistantLibraryModel
    var paneAccess: AgentPaneAccess?

    init(runtime: MobileAssistantModel, library: AssistantLibraryModel? = nil) {
        self.runtime = runtime
        self.library = library ?? AssistantLibraryModel(store: runtime.store)
        self.library.modelSelections = runtime.modelSelections
        runtime.configure(self.library.draftConversation)
    }

    var conversation: ConversationModel { library.selectedConversation ?? library.draftConversation }
    var speech: SpeechTranscriptionCoordinator { runtime.speech }
    var configuration: AIConfigurationModel { runtime.configuration }
    var skills: SkillLibraryModel { runtime.skills }
    var error: String? {
        get { runtime.error }
        set { runtime.error = newValue }
    }

    func load() async { await runtime.load() }
    func select(_ conversation: ConversationModel) { runtime.select(conversation, in: library) }
    func newConversation() { runtime.newConversation(in: library) }
    func send() { runtime.send(in: library, panes: paneAccess) }
    @discardableResult
    func selectModel(_ value: AIModelRef) -> Bool { runtime.selectModel(value, for: conversation) }

    func archive(_ conversation: ConversationModel, archived: Bool) async {
        await runtime.archive(conversation, archived: archived, in: library)
    }

    func rename(_ conversation: ConversationModel, title: String) async {
        await runtime.rename(conversation, title: title)
    }

    func move(_ conversation: ConversationModel, pinned: Bool, before: UUID? = nil) async {
        await runtime.move(conversation, pinned: pinned, before: before, in: library)
    }

    func delete(_ conversation: ConversationModel) async {
        await runtime.delete(conversation, from: library)
    }

    func fork(_ conversation: ConversationModel, at messageID: UUID) async {
        await runtime.fork(conversation, at: messageID, in: library)
    }

    func edit(_ conversation: ConversationModel, messageID: UUID, text: String) {
        runtime.edit(conversation, messageID: messageID, text: text, panes: paneAccess)
    }

    func compact(_ conversation: ConversationModel, instructions: String = "") async {
        await runtime.compact(conversation, instructions: instructions)
    }

    func implement(_ card: AgentPlanCard, in conversation: ConversationModel) {
        runtime.implement(card, in: conversation, library: library, panes: paneAccess)
    }
}
