import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import TermindApplication

@Suite @MainActor
struct AssistantNotificationTests {
    @Test(arguments: [false, true])
    func removingConversationOrStoppingCancelsDeliveryAndDetachesEvents(stop: Bool) async {
        let conversation = ConversationModel()
        let store = AssistantConversationStore(conversations: [conversation])
        let sender = NotificationDeliveryRecorder()
        let coordinator = AssistantNotificationCoordinator(
            service: sender, preferences: { .init() }, isFocused: { _ in false },
            content: AssistantNotificationContent.make)
        coordinator.observe(conversation)
        conversation.handle(.runFinished(.init(id: UUID(), state: .completed, startedAt: .now)))
        _ = await sender.nextRequest()
        if stop { coordinator.stop() } else { store.remove(conversation.id) }
        await sender.finishDelivery()
        #expect(sender.sent.isEmpty)
        let unread = conversation.unreadNotificationCount
        conversation.handle(.runFinished(.init(id: UUID(), state: .completed, startedAt: .now)))
        #expect(conversation.unreadNotificationCount == unread)
        #expect(conversation.notificationEvent == nil)
    }

    @Test func stoppingKeepsAlreadyDeliveredCompletionNotifications() async {
        let conversation = ConversationModel()
        let sender = NotificationDeliveryRecorder()
        let coordinator = AssistantNotificationCoordinator(
            service: sender, preferences: { .init() }, isFocused: { _ in false },
            content: AssistantNotificationContent.make)
        coordinator.observe(conversation)
        conversation.handle(.runFinished(.init(id: UUID(), state: .completed, startedAt: .now)))
        _ = await sender.nextRequest()
        await sender.finishDelivery()
        coordinator.stop()
        #expect(sender.sent.count == 1)
        #expect(sender.removed.isEmpty)
    }

    @Test func manuallyChangingUnreadStateIsIdempotentAndDoesNotSendNotifications() async {
        let fixture = AssistantNotificationFixture()
        let conversation = fixture.conversation
        conversation.markNotificationsUnread()
        conversation.markNotificationsUnread()
        #expect(conversation.unreadNotificationCount == 1)
        conversation.markNotificationsRead()
        #expect(conversation.unreadNotificationCount == 0)
        await settle()
        #expect(fixture.sender.sent.isEmpty)
        #expect(ConversationModel().unreadNotificationCount == 0)
    }

    @Test func completedNotificationUsesTheFinalReplyFromThatRun() async {
        let fixture = AssistantNotificationFixture()
        fixture.conversation.customTitle = "Deploy staging"
        let old = AgentRunSummary(id: UUID(), state: .running, startedAt: .now)
        fixture.conversation.handle(.runStarted(old))
        fixture.conversation.handle(.messageFinished(.init(role: .assistant, text: "Old reply")))
        var run = AgentRunSummary(id: UUID(), state: .running, startedAt: .now)
        fixture.conversation.handle(.runStarted(run))
        fixture.conversation.handle(.messageFinished(.init(role: .assistant, text: "Deployment is ready.")))
        run.state = .completed
        fixture.conversation.handle(.runFinished(run))
        await settle()
        #expect(fixture.sender.sent.last?.title == "Deploy staging")
        #expect(fixture.sender.sent.last?.body == "Deployment is ready.")
        let emptyRun = AgentRunSummary(id: UUID(), state: .completed, startedAt: .now)
        fixture.conversation.handle(.runFinished(emptyRun))
        await settle()
        #expect(fixture.sender.sent.last?.body != "Deployment is ready.")
    }

    @Test func unreadCountsAreIndependentOfSystemDeliveryAndResetWithTheModel() async {
        let fixture = AssistantNotificationFixture()
        fixture.settings.isEnabled = false
        let run = AgentRunSummary(id: UUID(), state: .completed, startedAt: .now)
        fixture.conversation.handle(.runFinished(run))
        fixture.conversation.handle(.runFinished(run))
        #expect(fixture.conversation.unreadNotificationCount == 1)
        let request = request()
        fixture.conversation.present(request)
        #expect(fixture.conversation.unreadNotificationCount == 2)
        fixture.conversation.cancelUserInput()
        #expect(fixture.conversation.unreadNotificationCount == 1)
        fixture.conversation.markNotificationsRead()
        #expect(fixture.conversation.unreadNotificationCount == 0)
        #expect(ConversationModel().unreadNotificationCount == 0)
        await settle()
        #expect(fixture.sender.sent.isEmpty)
    }

    @Test func globalAssistantSuppressionStillCountsUnseenConversationEvents() async {
        let conversation = ConversationModel()
        let sender = NotificationRecorder()
        let coordinator = AssistantNotificationCoordinator(
            service: sender, preferences: { .init() }, isFocused: { _ in true }, isVisible: { _ in false },
            content: AssistantNotificationContent.make)
        coordinator.observe(conversation)
        conversation.handle(.runFinished(.init(id: UUID(), state: .completed, startedAt: .now)))
        await settle()
        #expect(sender.sent.isEmpty)
        #expect(conversation.unreadNotificationCount == 1)
    }

    @Test func appBadgeTracksOnlyLiveUnreadCountsAndStopsAtZero() async {
        let conversation = ConversationModel()
        let sender = NotificationRecorder()
        let badge = NotificationBadgeCoordinator(service: sender) { conversation.unreadNotificationCount }
        #expect(sender.badgeCounts == [0])
        conversation.markNotificationUnread("first")
        conversation.markNotificationUnread("second")
        await settle()
        #expect(sender.badgeCounts.last == 2)
        conversation.markNotificationsRead()
        await settle()
        #expect(sender.badgeCounts.last == 0)
        badge.stop()
        conversation.markNotificationUnread("third")
        await settle()
        #expect(sender.badgeCounts.last == 0)
    }

    @Test func completedAndFailedRunsNotifyOnceWithoutReplacingOtherCallbacks() async {
        let fixture = AssistantNotificationFixture()
        var titleCalls = 0
        var memoryCalls = 0
        fixture.conversation.runDidFinish = { titleCalls += 1 }
        fixture.conversation.memoryRunFinished = { _, _, _, _ in memoryCalls += 1 }
        for state in [AgentRunState.completed, .failed, .cancelled, .interrupted] {
            let run = AgentRunSummary(id: UUID(), state: state, startedAt: .now, finishedAt: .now)
            fixture.conversation.handle(.runState(state))
            fixture.conversation.handle(.runFinished(run))
            fixture.conversation.handle(.runFinished(run))
        }
        await settle()
        #expect(fixture.sender.sent.count == 2)
        #expect(titleCalls == 4 && memoryCalls == 8)
        #expect(fixture.sender.sent.allSatisfy { $0.target == .assistant(fixture.conversation.id) })
    }

    @Test func preparationFailuresNotifyAndRestorationDoesNotReplay() async {
        let fixture = AssistantNotificationFixture()
        let snapshot = AgentRunSnapshot(
            conversationID: fixture.conversation.id, state: .failed,
            permissionMode: .askForApproval, failure: "Connection failed: password=secret-value")
        fixture.conversation.recordFailedRun(snapshot)
        fixture.conversation.recordFailedRun(snapshot)
        await settle()
        #expect(fixture.sender.sent.count == 1)
        #expect(fixture.sender.sent[0].body.contains("Connection failed"))
        #expect(!fixture.sender.sent[0].body.contains("secret-value"))
        let restored = ConversationModel(
            runState: .completed,
            runs: [.init(id: UUID(), state: .completed, startedAt: .now)])
        fixture.coordinator.observe(restored)
        await settle()
        #expect(fixture.sender.sent.count == 1)
    }

    @Test(arguments: NotificationPreferences.Mode.allCases, [false, true])
    func assistantModeUsesTheConversationFocus(_ mode: NotificationPreferences.Mode, focused: Bool) async {
        let fixture = AssistantNotificationFixture()
        fixture.settings.assistantMode = mode
        fixture.focused = focused
        let run = AgentRunSummary(id: UUID(), state: .completed, startedAt: .now)
        fixture.conversation.handle(.runFinished(run))
        await settle()
        #expect(fixture.sender.sent.count == (mode.allows(isFocused: focused) ? 1 : 0))
        fixture.settings.assistantMode = .always
        fixture.focused = false
        fixture.conversation.handle(.runFinished(run))
        await settle()
        #expect(fixture.sender.sent.count == (mode.allows(isFocused: focused) ? 1 : 0))
    }

    @Test func queueHeadsNotifyOnceAndResolvedOrStoppedRequestsAreRemoved() async throws {
        let fixture = AssistantNotificationFixture()
        let first = request()
        let second = request(secret: true, date: first.createdAt.addingTimeInterval(1))
        fixture.conversation.present(first)
        fixture.conversation.present(second)
        await settle()
        #expect(fixture.sender.sent.count == 1)
        fixture.conversation.cancelUserInput()
        await settle()
        #expect(fixture.sender.sent.count == 2)
        #expect(fixture.sender.removed.contains(fixture.sender.sent[0].id))
        #expect(fixture.conversation.notificationInteraction?.kind == .secret)
        fixture.conversation.handle(.runState(.cancelled))
        #expect(fixture.sender.removed.contains(fixture.sender.sent[1].id))
        fixture.conversation.cancelUserInput()
    }

    @Test func pendingDeliveryRechecksRequestAndSettingsAfterSuspension() async {
        let fixture = AssistantNotificationFixture()
        fixture.sender.hold = true
        fixture.conversation.present(request())
        await settle()
        #expect(fixture.sender.waiter != nil)
        fixture.conversation.cancelUserInput()
        fixture.sender.resume()
        await settle()
        #expect(fixture.sender.sent.isEmpty)
        fixture.conversation.present(request())
        await settle()
        fixture.settings.isEnabled = false
        fixture.sender.resume()
        await settle()
        #expect(fixture.sender.sent.isEmpty)
        fixture.conversation.cancelUserInput()
    }

    @Test func timeoutRemovesThePromptWithoutResettingItsDeadline() async {
        let fixture = AssistantNotificationFixture()
        var wake: CheckedContinuation<Void, Never>?
        fixture.conversation.questionClockSleep = { _ in await withCheckedContinuation { wake = $0 } }
        fixture.conversation.present(request())
        await settle()
        #expect(fixture.sender.sent.count == 1)
        wake?.resume()
        await settle()
        #expect(fixture.conversation.pendingUserInput == nil)
        #expect(fixture.sender.removed.contains(fixture.sender.sent[0].id))
    }

    @Test(arguments: [false, true])
    func authenticationAndPassphraseUseOnlyTheirCategory(passphrase: Bool) async {
        let fixture = AssistantNotificationFixture()
        let request = AgentSSHAuthenticationRequest(
            invocationID: UUID(), hostID: UUID(), displayName: "private-host",
            address: "secret.example", mode: passphrase ? .passphrase(keyID: UUID()) : .identity,
            username: "private-user")
        let task = Task { await fixture.conversation.requestSSHAuthentication(request) }
        await settle()
        #expect(fixture.conversation.notificationInteraction?.kind == (passphrase ? .passphrase : .authentication))
        #expect(fixture.sender.sent.count == 1)
        #expect(!fixture.sender.sent[0].body.contains("private"))
        fixture.conversation.respondToSSHAuthentication(.cancelled)
        _ = await task.value
        #expect(fixture.sender.removed.contains(fixture.sender.sent[0].id))
    }

    @Test func emptyKeyboardChallengeCompletesWithoutNotification() async {
        let fixture = AssistantNotificationFixture()
        let challenge = SSHKeyboardInteractiveChallenge(
            connectionID: UUID(), hostID: UUID(), hostname: "example",
            port: 22, username: "user", round: 0, name: "", instruction: "", prompts: [])
        let request = AgentSSHAuthenticationRequest(
            invocationID: UUID(), hostID: UUID(), displayName: "example",
            address: "example", mode: .keyboardInteractive(challenge), username: "user")
        _ = await fixture.conversation.requestSSHAuthentication(request)
        await settle()
        #expect(fixture.sender.sent.isEmpty)
    }

    @Test func hostKeyConfirmationAndApprovalFollowTheVisibleInteractionPriority() async {
        let fixture = AssistantNotificationFixture()
        let question = request()
        fixture.conversation.present(question)
        await settle()
        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(id: "call", name: "review", arguments: .object([:])))
        let approval = AgentApprovalRequest(
            invocation: invocation,
            descriptor: .init(
                name: "review", summary: "private", inputSchema: .object([:]),
                target: .host, approvalPolicy: .ask), userIntent: "private-intent")
        let approvalTask = Task { await fixture.conversation.requestApproval(approval) }
        let hostKey = AgentSSHHostKeyRequest(
            createdAt: question.createdAt.addingTimeInterval(1), invocationID: UUID(), hostID: UUID(),
            displayName: "private-host", address: "private.example",
            prompt: .init(
                observation: .init(
                    hostname: "private.example", port: 22, algorithm: .ed25519,
                    fingerprint: "private-fingerprint"), kind: .firstUse), allowsPersistentTrust: true)
        let hostTask = Task { await fixture.conversation.requestSSHHostKeyConfirmation(hostKey) }
        await settle()
        #expect(fixture.sender.sent.count == 1)
        fixture.conversation.cancelUserInput()
        await settle()
        #expect(fixture.conversation.notificationInteraction?.kind == .hostKey)
        #expect(fixture.sender.sent.count == 2)
        fixture.conversation.respondToSSHHostKey(.deny)
        _ = await hostTask.value
        await settle()
        #expect(fixture.conversation.notificationInteraction?.kind == .approval)
        #expect(fixture.sender.sent.count == 3)
        fixture.conversation.respondToApproval(approval.id, allow: false)
        _ = await approvalTask.value
        #expect(fixture.sender.removed.count == 3)
        #expect(fixture.sender.sent.allSatisfy { !$0.body.contains("private") })
    }

    @Test func questionPagingDoesNotNotifyAgainOrMoveTheDeadline() async {
        let fixture = AssistantNotificationFixture()
        let request = AgentUserInputRequest(questions: [
            .init(id: "first", prompt: "First", kind: .text),
            .init(id: "second", prompt: "Second", kind: .text),
        ])
        fixture.conversation.present(request)
        let deadline = fixture.conversation.userInputDeadline
        await settle()
        fixture.conversation.skipUserInputQuestion()
        await settle()
        #expect(fixture.sender.sent.count == 1)
        #expect(fixture.conversation.userInputDeadline == deadline)
        fixture.conversation.cancelUserInput()
    }

    @Test func notificationTitlesMatchTheConversationTitleAndInteractionBodiesExcludePrompts() {
        let conversation = ConversationModel(messages: [.init(role: .user, text: "password=secret")])
        let text = AssistantNotificationContent.make(conversation, kind: .questions)
        #expect(text.title == conversation.derivedTitle)
        #expect(!text.body.contains("password"))
        conversation.customTitle = "Build\nstatus"
        #expect(AssistantNotificationContent.make(conversation, kind: .completed).title == "Build status")
    }

    private func request(secret: Bool = false, date: Date = .now) -> AgentUserInputRequest {
        .init(createdAt: date, questions: [.init(id: "q", prompt: "private-prompt", kind: secret ? .secret : .text)])
    }

    private func settle() async { for _ in 0..<30 { await Task.yield() } }
}

@MainActor private final class AssistantNotificationFixture {
    let conversation = ConversationModel()
    let sender = NotificationRecorder()
    var settings = NotificationPreferences()
    var focused = false
    lazy var coordinator = AssistantNotificationCoordinator(
        service: sender,
        preferences: { [unowned self] in settings }, isFocused: { [unowned self] _ in focused },
        content: AssistantNotificationContent.make)
    init() {
        settings.isEnabled = true
        coordinator.observe(conversation)
    }
}

@MainActor private final class NotificationRecorder: NotificationSending {
    var sent: [AppNotification] = []
    var removed: [String] = []
    var badgeCounts: [Int] = []
    func setBadgeCount(_ count: Int) { badgeCounts.append(count) }
    var hold = false
    var waiter: CheckedContinuation<Void, Never>?
    func authorization(request: Bool) async -> NotificationAuthorization { .allowed }
    func send(_ notification: AppNotification, ifCurrent: @escaping @MainActor () -> Bool) async {
        if hold { await withCheckedContinuation { waiter = $0 } }
        guard !Task.isCancelled, ifCurrent() else { return }
        sent.append(notification)
    }
    func remove(_ identifiers: [String]) { removed.append(contentsOf: identifiers) }
    func resume() {
        waiter?.resume()
        waiter = nil
    }
}
