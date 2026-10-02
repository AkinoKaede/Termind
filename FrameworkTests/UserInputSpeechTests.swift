import AgentKit
import Foundation
import Testing

@testable import TermindApplication

@Suite @MainActor
struct UserInputSpeechTests {
    @Test(arguments: ["", "Existing", "Existing\n"])
    func finalSpeechAppendsToTheAnswerWithoutSubmittingOrChangingChat(initial: String) async throws {
        let (conversation, request) = fixture()
        conversation.setUserInputCustomAnswer(initial, for: "answer")
        conversation.composer.draft = "Chat draft"
        let service = QuestionSpeechService()
        let speech = SpeechTranscriptionCoordinator(service: service)
        let session = UserInputSpeechSession()
        var applied = 0
        session.start(coordinator: speech, conversation: conversation) { applied += 1 }
        #expect(session.isActive)
        try await eventually { session.isRecording }
        service.emit(.partial("Partial"))
        #expect(conversation.userInputDraft(for: "answer").text == initial)
        session.stop()
        #expect(speech.phase == .transcribing)
        #expect(session.isActive)
        #expect(!session.isRecording)
        service.emit(.final("  Voice text \n"))

        let separator = initial.isEmpty || initial.last?.isWhitespace == true ? "" : " "
        #expect(conversation.userInputDraft(for: "answer").text == initial + separator + "Voice text")
        #expect(conversation.pendingUserInput?.id == request.id)
        #expect(conversation.currentUserInputQuestionIndex == 0)
        #expect(conversation.composer.draft == "Chat draft")
        #expect(conversation.messages.isEmpty)
        #expect(applied == 1)
        #expect(!session.isActive)
        conversation.cancelUserInput()
    }

    @Test(arguments: [false, true])
    func spokenCustomAnswersFollowExistingChoiceSemantics(multiple: Bool) {
        let choice = AgentUserInputChoice(
            options: [AgentUserInputOption(id: "option", label: "Option")],
            allowsCustomAnswer: true, allowsMultipleAnswers: multiple)
        let (conversation, request) = fixture(kind: .choice(choice))
        conversation.toggleUserInputOption("option", in: "answer")
        #expect(conversation.applyUserInputTranscription("Custom", requestID: request.id, questionID: "answer"))
        #expect(conversation.userInputDraft(for: "answer").selection == (multiple ? ["option"] : []))
        #expect(conversation.userInputDraft(for: "answer").text == "Custom")
        #expect(conversation.pendingUserInput?.id == request.id)
        conversation.cancelUserInput()
    }

    @Test(arguments: [false, true])
    func cancellingRecordingOrFinalizationPreservesTheOriginalAnswer(finishing: Bool) async throws {
        let (conversation, _) = fixture()
        conversation.setUserInputCustomAnswer("Original", for: "answer")
        let service = QuestionSpeechService()
        let speech = SpeechTranscriptionCoordinator(service: service)
        let session = UserInputSpeechSession()
        session.start(coordinator: speech, conversation: conversation) { Issue.record("Unexpected completion") }
        try await eventually { session.isRecording }
        if finishing { session.stop() }
        session.cancel()
        service.emit(.final("Late text"))
        #expect(!session.isActive)
        #expect(speech.ownerID == nil)
        #expect(service.cancelCount == 1)
        #expect(conversation.userInputDraft(for: "answer").text == "Original")
        conversation.cancelUserInput()
    }

    @Test func cancellationBeforeTheStartTaskRunsCannotAcquireTheMicrophone() async {
        let (conversation, _) = fixture()
        let service = QuestionSpeechService()
        let speech = SpeechTranscriptionCoordinator(service: service)
        let session = UserInputSpeechSession()
        session.start(coordinator: speech, conversation: conversation) { Issue.record("Unexpected completion") }
        session.cancel()
        await Task.yield()
        #expect(service.startCount == 0)
        #expect(speech.ownerID == nil)
        #expect(!session.isActive)
        conversation.cancelUserInput()
    }

    @Test func aRetiredQuestionBeforeTheStartTaskRunsDoesNotLeaveTheFieldBusy() async throws {
        let (conversation, _) = fixture()
        let service = QuestionSpeechService()
        let speech = SpeechTranscriptionCoordinator(service: service)
        let session = UserInputSpeechSession()
        session.start(coordinator: speech, conversation: conversation) { Issue.record("Unexpected completion") }
        conversation.cancelUserInput()
        try await eventually { !session.isActive }
        #expect(service.startCount == 0)
        #expect(speech.ownerID == nil)
    }

    @Test func permissionCompletionAfterLeavingTheQuestionCannotStartRecording() async throws {
        let (conversation, _) = fixture()
        let service = QuestionSpeechService()
        service.suspendsAuthorization = true
        let speech = SpeechTranscriptionCoordinator(service: service)
        let session = UserInputSpeechSession()
        session.start(coordinator: speech, conversation: conversation) { Issue.record("Unexpected completion") }
        try await eventually { service.authorization != nil }
        #expect(session.isActive)
        session.cancel()
        service.authorization?.resume()
        service.authorization = nil
        await Task.yield()
        #expect(service.startCount == 0)
        #expect(speech.ownerID == nil)
        #expect(!session.isActive)
        conversation.cancelUserInput()
    }

    @Test(arguments: ["question", "replacement", "cancel"])
    func aLateFinalResultCannotPopulateAnotherQuestionOrRequest(change: String) async throws {
        let (conversation, _) = fixture()
        let service = QuestionSpeechService()
        let speech = SpeechTranscriptionCoordinator(service: service)
        let session = UserInputSpeechSession()
        session.start(coordinator: speech, conversation: conversation) { Issue.record("Unexpected completion") }
        try await eventually { session.isRecording }
        session.stop()
        if change == "question" {
            conversation.skipUserInputQuestion()
        } else {
            conversation.cancelUserInput()
            if change == "replacement" {
                conversation.present(
                    AgentUserInputRequest(questions: [
                        AgentUserQuestion(id: "answer", prompt: "New request", kind: .text)
                    ]))
            }
        }
        // Deliberately deliver before the view's onChange cancellation runs.
        service.emit(.final("Stale text"))
        #expect(conversation.userInputDraft(for: "answer").text.isEmpty)
        #expect(conversation.userInputDraft(for: "second").text.isEmpty)
        #expect(conversation.composer.draft.isEmpty)
        session.cancel()
        conversation.cancelUserInput()
    }

    @Test func aTimedOutRequestRejectsTheFinalResult() async throws {
        let (conversation, original) = fixture()
        conversation.cancelUserInput()
        var request = original
        request.timeout = .milliseconds(40)
        conversation.present(request)
        let service = QuestionSpeechService()
        let speech = SpeechTranscriptionCoordinator(service: service)
        let session = UserInputSpeechSession()
        session.start(coordinator: speech, conversation: conversation) { Issue.record("Unexpected completion") }
        try await eventually { session.isRecording }
        try await eventually { conversation.pendingUserInput == nil }
        service.emit(.final("Late text"))
        #expect(conversation.userInputDrafts.isEmpty)
        session.cancel()
    }

    @Test func aQuestionCannotStealOrCancelAnotherSurfacesMicrophone() async throws {
        let (conversation, _) = fixture()
        let service = QuestionSpeechService()
        let speech = SpeechTranscriptionCoordinator(service: service)
        let composerOwner = UUID()
        await speech.start(ownerID: composerOwner) { _, _ in }
        let session = UserInputSpeechSession()
        session.start(coordinator: speech, conversation: conversation) { Issue.record("Unexpected completion") }
        session.cancel()
        #expect(!session.isActive)
        #expect(speech.ownerID == composerOwner)
        #expect(service.startCount == 1)
        #expect(service.cancelCount == 0)
        speech.cancel(ownerID: composerOwner)
        session.start(coordinator: speech, conversation: conversation) {}
        try await eventually { session.isRecording }
        let secondSurface = UserInputSpeechSession()
        secondSurface.start(coordinator: speech, conversation: conversation) { Issue.record("Unexpected completion") }
        secondSurface.cancel()
        #expect(speech.ownerID == session.ownerID)
        session.cancel()
        conversation.cancelUserInput()
    }

    @Test(arguments: ["empty", "noSpeech", "permission", "failure"])
    func unsuccessfulSpeechPreservesAnswersAndReportsOnlyActionableErrors(outcome: String) async throws {
        let (conversation, _) = fixture()
        conversation.setUserInputCustomAnswer("Original", for: "answer")
        let service = QuestionSpeechService()
        if outcome == "permission" { service.authorizationError = .init(.microphonePermissionDenied) }
        let speech = SpeechTranscriptionCoordinator(service: service)
        let session = UserInputSpeechSession()
        session.start(coordinator: speech, conversation: conversation) { Issue.record("Unexpected completion") }
        if outcome == "permission" {
            try await eventually { session.error != nil }
        } else {
            try await eventually { session.isRecording }
            switch outcome {
            case "empty": service.emit(.final("  \n"))
            case "noSpeech": service.emit(.failure(.init(.noSpeech)))
            default: service.emit(.failure(.init(.recognitionFailed)))
            }
        }
        #expect(!session.isActive)
        #expect((session.error != nil) == (outcome == "permission" || outcome == "failure"))
        #expect(conversation.userInputDraft(for: "answer").text == "Original")
        session.dismissError()
        #expect(session.error == nil)
        conversation.cancelUserInput()
    }

    @Test(arguments: [false, true])
    func secretAndClosedChoiceQuestionsCannotStartSpeech(secret: Bool) {
        let kind: AgentUserQuestion.Kind =
            secret
            ? .secret
            : .choice(
                AgentUserInputChoice(
                    options: [AgentUserInputOption(id: "option", label: "Option")], allowsCustomAnswer: false))
        let (conversation, request) = fixture(kind: kind)
        let speech = SpeechTranscriptionCoordinator(service: QuestionSpeechService())
        let session = UserInputSpeechSession()
        session.start(coordinator: speech, conversation: conversation) { Issue.record("Unexpected completion") }
        #expect(!session.isActive)
        #expect(!conversation.applyUserInputTranscription("Text", requestID: request.id, questionID: "answer"))
        #expect(conversation.secretInputDraft.isEmpty)
        #expect(conversation.userInputDrafts.isEmpty)
        conversation.cancelUserInput()
    }

    private func fixture(kind: AgentUserQuestion.Kind = .text) -> (ConversationModel, AgentUserInputRequest) {
        let conversation = ConversationModel()
        let request = AgentUserInputRequest(questions: [
            AgentUserQuestion(id: "answer", prompt: "Answer", kind: kind),
            AgentUserQuestion(id: "second", prompt: "Second", kind: .text),
        ])
        conversation.present(request)
        return (conversation, request)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}

@MainActor
private final class QuestionSpeechService: SpeechTranscriptionService {
    var handler: (@MainActor (SpeechTranscriptionEvent) -> Void)?
    var suspendsAuthorization = false
    var authorization: CheckedContinuation<Void, Never>?
    var authorizationError: SpeechTranscriptionFailure?
    var startCount = 0
    var cancelCount = 0

    func requestAuthorization() async throws {
        if suspendsAuthorization { await withCheckedContinuation { authorization = $0 } }
        if let authorizationError { throw authorizationError }
    }

    func start(locale: Locale, eventHandler: @escaping @MainActor (SpeechTranscriptionEvent) -> Void) throws {
        startCount += 1
        handler = eventHandler
    }

    func finish() {}
    func cancel() { cancelCount += 1 }
    func emit(_ event: SpeechTranscriptionEvent) { handler?(event) }
}
