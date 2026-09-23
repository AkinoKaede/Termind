import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import Testing

@testable import Termind

@Suite(.timeLimit(.minutes(1))) @MainActor
struct AppTerminationTests {
    @Test
    func shutdownCancelsEveryStoredConversationBeforeAwaitingAndClosesResourcesAfterDrains() async throws {
        let events = TerminationEventLog()
        let firstRepository = TerminationRepository(
            blocksTerminalSave: true,
            terminalSaved: { await events.append("save") })
        let secondRepository = TerminationRepository()
        let firstCalls = TerminationModelCalls()
        let secondCalls = TerminationModelCalls()
        let first = queuedConversation(repository: firstRepository, calls: firstCalls)
        let second = queuedConversation(repository: secondRepository, calls: secondCalls)
        let store = AssistantConversationStore(conversations: [first, second])
        let app = makeApp(
            repository: firstRepository, store: store,
            shutdown: AppShutdownDependencies(
                stopMCP: { await events.append("mcp") },
                stopSFTP: { await events.append("sftp") },
                closeAgentBackgroundCommands: { await events.append("background") },
                closeAgentConnections: { await events.append("connections") }
            ))
        let window = WindowModel()
        app.registerWindow(window)
        #expect(window.assistantLibrary.conversation(id: first.id) === first)
        window.openAssistantInSidebar(second.id)
        #expect(window.assistantLibrary.selectedConversationID == second.id)
        app.unregisterWindow(window)

        let cleanup = app.shutdownForTermination()
        let repeatedCleanup = app.shutdownForTermination()
        await firstRepository.waitForTerminalSave()

        #expect(first.runState == .cancelled)
        #expect(second.runState == .cancelled)
        #expect(await firstCalls.count == 0)
        #expect(await secondCalls.count == 0)
        #expect(!(await events.values).contains("background"))
        #expect(!(await events.values).contains("connections"))

        await firstRepository.releaseTerminalSaves()
        await cleanup.value
        await repeatedCleanup.value

        let values = await events.values
        let save = try #require(values.firstIndex(of: "save"))
        let background = try #require(values.firstIndex(of: "background"))
        let connections = try #require(values.firstIndex(of: "connections"))
        #expect(values.filter { $0 == "mcp" }.count == 1)
        #expect(values.filter { $0 == "sftp" }.count == 1)
        #expect(values.filter { $0 == "background" }.count == 1)
        #expect(values.filter { $0 == "connections" }.count == 1)
        #expect(save < background)
        #expect(background < connections)
        #expect(await firstRepository.savedTerminalState == .cancelled)
        #expect(await secondRepository.savedTerminalState == .cancelled)
    }

    @Test
    func shutdownFencesEveryAssistantAdmissionAndInvalidatesAnAlreadyPreparedEdit() async throws {
        let repository = TerminationRepository()
        let original = AgentTranscriptMessage(role: .user, text: "before", authoredText: "before")
        let preparedEdit = ConversationModel(
            messages: [ChatMessage(id: original.id, role: .user, text: original.text)],
            transcript: [original])
        let draft = ConversationModel()
        draft.composer.draft = "draft after shutdown"
        let normal = ConversationModel()
        let directStart = ConversationModel()
        let planConversation = ConversationModel()
        let plan = AgentPlan(
            title: "Shutdown plan", body: "Must not run", scratchPath: "/tmp/shutdown-plan.md")
        planConversation.isPlanning = true
        planConversation.handle(.planPresented(plan))
        let postFenceEditMessage = AgentTranscriptMessage(role: .user, text: "edit me", authoredText: "edit me")
        let postFenceEdit = ConversationModel(
            messages: [ChatMessage(id: postFenceEditMessage.id, role: .user, text: postFenceEditMessage.text)],
            transcript: [postFenceEditMessage])
        let store = AssistantConversationStore(
            conversations: [preparedEdit, draft, normal, directStart, planConversation, postFenceEdit])
        let app = makeApp(repository: repository, store: store)
        let window = WindowModel()
        app.registerWindow(window)

        window.assistantCommands?.edit(
            preparedEdit.id, original.id, "prepared before shutdown", .none, false)
        #expect(preparedEdit.isPreparingAgentRun)
        let cleanup = app.shutdownForTermination()

        app.sendAgentDraft(draft)
        let newConversation = ConversationModel()
        newConversation.composer.draft = "new conversation after shutdown"
        #expect(app.sendNewAgentConversation(newConversation, in: window.assistantLibrary) == nil)
        window.assistantLibrary.draftConversation.composer.draft = "new after shutdown"
        #expect(app.sendNewAgentDraft(in: window.assistantLibrary) == nil)
        #expect(!app.sendAgentText("normal after shutdown", in: normal))

        let planCard = try #require(planConversation.plans.first)
        #expect(!app.sendPlanImplementation(planCard, in: planConversation))

        app.startAgentRun(
            directStart, prompt: "explicit start after shutdown",
            authoredPrompt: "explicit start after shutdown")
        window.assistantCommands?.edit(
            postFenceEdit.id, postFenceEditMessage.id, "edit after shutdown", .none, false)

        await cleanup.value
        for _ in 0..<10 { await Task.yield() }

        #expect(preparedEdit.transcript == [original])
        #expect(draft.transcript.isEmpty)
        #expect(draft.composer.draft == "draft after shutdown")
        #expect(normal.transcript.isEmpty)
        #expect(directStart.transcript.isEmpty)
        #expect(planConversation.plans.first?.outcome == .pending)
        #expect(planConversation.isPlanning)
        #expect(postFenceEdit.transcript == [postFenceEditMessage])
        #expect(newConversation.transcript.isEmpty)
        #expect(await repository.truncationCount == 0)
        #expect(await repository.savedSnapshots.map(\.state) == [.interrupted])
    }

    @Test
    func shutdownJoinsAnUnstoredCapturedFailureBeforeClosingResources() async {
        let events = TerminationEventLog()
        let repository = TerminationRepository(
            blocksTerminalSave: true,
            terminalSaved: { await events.append("save") })
        let app = makeApp(
            repository: repository,
            shutdown: AppShutdownDependencies(
                stopMCP: {}, stopSFTP: {},
                closeAgentBackgroundCommands: { await events.append("background") },
                closeAgentConnections: { await events.append("connections") }))
        let conversation = ConversationModel()

        #expect(app.sendAgentText("captured failure", in: conversation))
        await repository.waitForTerminalSave()
        #expect(conversation.isPersistingAgentPreparationFailure)

        let cleanup = app.shutdownForTermination()
        for _ in 0..<10 { await Task.yield() }
        #expect(!(await events.values).contains("background"))
        #expect(await repository.savedSnapshots.map(\.state) == [.failed])

        await repository.releaseTerminalSaves()
        await cleanup.value

        #expect(conversation.runState == .failed)
        #expect(await repository.savedSnapshots.map(\.state) == [.failed])
        #expect(await events.values == ["save", "background", "connections"])
    }

    @Test
    func terminationReplyFallsBackWhenCleanupHangsAndRepliesOnlyOnce() async {
        let cleanupGate = TerminationGate()
        let fallbackGate = TerminationGate()
        let replies = TerminationReplyCount()
        let cleanup = Task { await cleanupGate.wait() }
        let coordinator = AppTerminationReplyCoordinator()

        coordinator.begin(
            cleanup: cleanup, timeout: .seconds(3),
            sleep: { duration in
                #expect(duration == .seconds(3))
                await fallbackGate.wait()
            },
            reply: { replies.value += 1 })

        await fallbackGate.waitUntilEntered()
        #expect(replies.value == 0)
        await fallbackGate.release()
        await waitUntil { replies.value == 1 }

        await cleanupGate.release()
        await cleanup.value
        for _ in 0..<10 { await Task.yield() }
        #expect(replies.value == 1)

        let lateFallback = TerminationGate()
        let cleanupFirstReplies = TerminationReplyCount()
        let cleanupFirst = AppTerminationReplyCoordinator()
        cleanupFirst.begin(
            cleanup: Task {},
            sleep: { _ in await lateFallback.wait() },
            reply: { cleanupFirstReplies.value += 1 })
        await waitUntil { cleanupFirstReplies.value == 1 }
        await lateFallback.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(cleanupFirstReplies.value == 1)
    }

    private func queuedConversation(
        repository: any AgentRunPersisting, calls: TerminationModelCalls
    ) -> ConversationModel {
        let conversation = ConversationModel()
        let runtime = AgentRuntime(
            model: TerminationCountingModel(calls: calls), tools: [],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .deny("test") }),
            repository: repository)
        conversation.start(
            runtime: runtime,
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "queued",
                permissionMode: .askForApproval),
            repository: repository)
        return conversation
    }

    private func makeApp(
        repository: any AgentRunPersisting,
        store: AssistantConversationStore = AssistantConversationStore(),
        shutdown: AppShutdownDependencies? = nil
    ) -> AppModel {
        let defaults = UserDefaults(suiteName: "termind.tests.termination.\(UUID().uuidString)")!
        return AppModel(
            hosts: HostLibraryModel(),
            dependencies: AppDependencies(
                hostRepository: InMemoryHostRepository(),
                outboxRunner: nil,
                agentRunRepository: repository,
                settingsDefaults: defaults,
                assistantConversations: store,
                shutdown: shutdown))
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        while !condition() { await Task.yield() }
    }
}

private struct TerminationCountingModel: AgentModelStreaming {
    let calls: TerminationModelCalls

    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await calls.called()
                continuation.yield(.finished(.completed))
                continuation.finish()
            }
        }
    }
}

private actor TerminationModelCalls {
    private(set) var count = 0
    func called() { count += 1 }
}

private actor TerminationEventLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor TerminationGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll()
        for waiter in waitingForEntry { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waitingForRelease { waiter.resume() }
    }
}

@MainActor
private final class TerminationReplyCount {
    var value = 0
}

private actor TerminationRepository: AgentRunPersisting {
    private let blocksTerminalSave: Bool
    private let terminalSaved: (@Sendable () async -> Void)?
    private var terminalSaveEntered = false
    private var terminalSaveWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminalReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var savedTerminalState: AgentRunState?
    private(set) var savedSnapshots: [AgentRunSnapshot] = []
    private(set) var truncationCount = 0

    init(
        blocksTerminalSave: Bool = false,
        terminalSaved: (@Sendable () async -> Void)? = nil
    ) {
        self.blocksTerminalSave = blocksTerminalSave
        self.terminalSaved = terminalSaved
    }

    func save(_ snapshot: AgentRunSnapshot) async {
        savedSnapshots.append(snapshot)
        guard snapshot.state.isTerminal else { return }
        terminalSaveEntered = true
        let waiters = terminalSaveWaiters
        terminalSaveWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if blocksTerminalSave {
            await withCheckedContinuation { terminalReleaseWaiters.append($0) }
        }
        await terminalSaved?()
        savedTerminalState = snapshot.state
    }

    func waitForTerminalSave() async {
        guard !terminalSaveEntered else { return }
        await withCheckedContinuation { terminalSaveWaiters.append($0) }
    }

    func releaseTerminalSaves() {
        let waiters = terminalReleaseWaiters
        terminalReleaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func record(_ event: AgentEvent, runID: UUID) {}
    func persistCompaction(_ record: AgentCompactionRecord, conversationID: UUID) {}
    func loadConversations() -> [StoredAgentConversation] { [] }
    func deleteConversation(_ id: UUID) {}
    func setTitle(_ title: String, conversationID: UUID) {}
    func setConversationMetadata(_ metadata: StoredAgentConversationMetadata, conversationID: UUID) {}
    func reorderConversations(_ updates: [StoredAgentConversationOrder]) {}
    func truncateConversation(
        _ id: UUID, fromUserMessageID messageID: UUID,
        replacingWith message: AgentTranscriptMessage
    ) {
        truncationCount += 1
    }
    func createConversation(_ conversation: StoredAgentConversation) {}
}
