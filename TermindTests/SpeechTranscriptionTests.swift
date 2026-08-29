import Foundation
import Testing

@testable import Termind

@Suite
@MainActor
struct SpeechTranscriptionTests {
    @Test
    func coordinatorMovesThroughRecordingAndTranscribingBeforeCompleting() async {
        let service = FakeSpeechTranscriptionService()
        let coordinator = SpeechTranscriptionCoordinator(service: service, sampleCount: 8)
        let ownerID = UUID()
        var completion: (String, Bool)?

        let started = await coordinator.start(ownerID: ownerID) { transcript, shouldSend in
            completion = (transcript, shouldSend)
        }

        #expect(started)
        #expect(coordinator.phase == .recording)
        #expect(coordinator.ownerID == ownerID)
        service.emit(.level(0.72))
        #expect(coordinator.levelSamples.last == 0.72)

        coordinator.stop(ownerID: ownerID, sendAfterTranscription: true)
        #expect(coordinator.phase == .transcribing)
        #expect(service.finishCount == 1)

        service.emit(.final("  hello from speech  "))
        #expect(coordinator.phase == .idle)
        #expect(coordinator.ownerID == nil)
        #expect(completion?.0 == "hello from speech")
        #expect(completion?.1 == true)
    }

    @Test
    func cancellationDiscardsResultAndIgnoresTheOldSessionCallback() async {
        let service = FakeSpeechTranscriptionService()
        let coordinator = SpeechTranscriptionCoordinator(service: service)
        let ownerID = UUID()
        var completionCount = 0

        _ = await coordinator.start(ownerID: ownerID) { _, _ in completionCount += 1 }
        let staleHandler = service.handlers[0]
        coordinator.cancel(ownerID: ownerID)

        staleHandler(.final("must be ignored"))
        #expect(coordinator.phase == .idle)
        #expect(coordinator.ownerID == nil)
        #expect(completionCount == 0)
        #expect(service.cancelCount == 1)
    }

    @Test
    func cancellationAlsoStopsAPendingFinalTranscription() async {
        let service = FakeSpeechTranscriptionService()
        let coordinator = SpeechTranscriptionCoordinator(service: service)
        let ownerID = UUID()
        var completed = false

        _ = await coordinator.start(ownerID: ownerID) { _, _ in completed = true }
        coordinator.stop(ownerID: ownerID)
        #expect(coordinator.phase == .transcribing)

        coordinator.cancel(ownerID: ownerID)
        service.emit(.final("late result"))

        #expect(coordinator.phase == .idle)
        #expect(!completed)
        #expect(service.cancelCount == 1)
    }

    @Test
    func onlyOneComposerCanOwnTheMicrophone() async {
        let service = FakeSpeechTranscriptionService()
        let coordinator = SpeechTranscriptionCoordinator(service: service)
        let firstOwner = UUID()
        let secondOwner = UUID()

        let firstStarted = await coordinator.start(ownerID: firstOwner) { _, _ in }
        let secondStarted = await coordinator.start(ownerID: secondOwner) { _, _ in }

        #expect(firstStarted)
        #expect(!secondStarted)
        #expect(coordinator.ownerID == firstOwner)
        #expect(!coordinator.canStart(for: secondOwner))
        #expect(service.startCount == 1)
    }

    @Test
    func authorizationFailureReturnsToIdleAndTargetsTheOwningComposer() async {
        let service = FakeSpeechTranscriptionService()
        service.authorizationError = SpeechTranscriptionFailure(.microphonePermissionDenied)
        let coordinator = SpeechTranscriptionCoordinator(service: service)
        let ownerID = UUID()

        let started = await coordinator.start(ownerID: ownerID) { _, _ in }

        #expect(!started)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.ownerID == nil)
        #expect(coordinator.error?.code == .microphonePermissionDenied)
        #expect(coordinator.errorOwnerID == ownerID)
        #expect(coordinator.error?.offersSystemSettings == true)

        coordinator.dismissError(ownerID: ownerID)
        #expect(coordinator.error == nil)
        #expect(coordinator.errorOwnerID == nil)
    }

    @Test
    func emptyFinalResultSilentlyReturnsToIdleWithoutCompletingOrAutoSending() async {
        let service = FakeSpeechTranscriptionService()
        let coordinator = SpeechTranscriptionCoordinator(service: service)
        let ownerID = UUID()
        var completed = false

        _ = await coordinator.start(ownerID: ownerID) { _, _ in completed = true }
        coordinator.stop(ownerID: ownerID, sendAfterTranscription: true)
        service.emit(.final(" \n "))

        #expect(!completed)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.error == nil)
        #expect(coordinator.errorOwnerID == nil)
    }

    @Test
    func noSpeechServiceFailureIsAlsoSilent() async {
        let service = FakeSpeechTranscriptionService()
        let coordinator = SpeechTranscriptionCoordinator(service: service)
        let ownerID = UUID()
        var completed = false

        _ = await coordinator.start(ownerID: ownerID) { _, _ in completed = true }
        service.emit(.failure(SpeechTranscriptionFailure(.noSpeech)))

        #expect(!completed)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.error == nil)
        #expect(coordinator.errorOwnerID == nil)
    }

    @Test
    func serviceFailureNeverCompletesPendingSend() async {
        let service = FakeSpeechTranscriptionService()
        let coordinator = SpeechTranscriptionCoordinator(service: service)
        let ownerID = UUID()
        var completed = false

        _ = await coordinator.start(ownerID: ownerID) { _, _ in completed = true }
        coordinator.stop(ownerID: ownerID, sendAfterTranscription: true)
        service.emit(.failure(SpeechTranscriptionFailure(.recognitionFailed, detail: "Network unavailable")))

        #expect(!completed)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.error?.message == "Network unavailable")
    }

    @Test
    func aCallbackFromACancelledSessionCannotAffectANewerSession() async {
        let service = FakeSpeechTranscriptionService()
        let coordinator = SpeechTranscriptionCoordinator(service: service)
        let firstOwner = UUID()
        let secondOwner = UUID()
        var secondResult: String?

        _ = await coordinator.start(ownerID: firstOwner) { _, _ in }
        let staleHandler = service.handlers[0]
        coordinator.cancel(ownerID: firstOwner)
        _ = await coordinator.start(ownerID: secondOwner) { transcript, _ in secondResult = transcript }

        staleHandler(.final("stale"))
        #expect(coordinator.phase == .recording)
        #expect(coordinator.ownerID == secondOwner)
        #expect(secondResult == nil)

        service.handlers[1](.final("current"))
        #expect(secondResult == "current")
    }

    @Test
    func transcriptionAppendsWithOnlyTheNecessarySeparator() {
        let empty = ConversationModel()
        let word = ConversationModel()
        let spaced = ConversationModel()
        word.composer.draft = "Existing"
        spaced.composer.draft = "Existing\n"

        #expect(empty.applyTranscription("  Voice text  ", sendAfterTranscription: false, send: {}))
        #expect(word.applyTranscription("Voice text", sendAfterTranscription: false, send: {}))
        #expect(spaced.applyTranscription("Voice text", sendAfterTranscription: false, send: {}))

        #expect(empty.composer.draft == "Voice text")
        #expect(word.composer.draft == "Existing Voice text")
        #expect(spaced.composer.draft == "Existing\nVoice text")
    }

    @Test
    func autoSendUsesTheProvidedComposerSendPathOnlyForValidSpeech() {
        let custom = ConversationModel()
        var customSendCount = 0

        let applied = custom.applyTranscription(
            "Create a new chat",
            sendAfterTranscription: true,
            send: { customSendCount += 1 }
        )
        let emptyApplied = custom.applyTranscription(
            "   ",
            sendAfterTranscription: true,
            send: { customSendCount += 1 }
        )

        #expect(applied)
        #expect(!emptyApplied)
        #expect(customSendCount == 1)
        #expect(custom.composer.draft == "Create a new chat")

        let ordinary = ConversationModel()
        _ = ordinary.applyTranscription(
            "Send me",
            sendAfterTranscription: true,
            send: { ordinary.sendDraft() }
        )
        #expect(ordinary.composer.draft.isEmpty)
        #expect(ordinary.messages.map(\.text) == ["Send me"])
    }
}

@MainActor
private final class FakeSpeechTranscriptionService: SpeechTranscriptionService {
    var authorizationError: SpeechTranscriptionFailure?
    var handlers: [@MainActor (SpeechTranscriptionEvent) -> Void] = []
    var startCount = 0
    var finishCount = 0
    var cancelCount = 0

    func requestAuthorization() async throws {
        if let authorizationError { throw authorizationError }
    }

    func start(
        locale: Locale,
        eventHandler: @escaping @MainActor (SpeechTranscriptionEvent) -> Void
    ) throws {
        startCount += 1
        handlers.append(eventHandler)
    }

    func finish() {
        finishCount += 1
    }

    func cancel() {
        cancelCount += 1
    }

    func emit(_ event: SpeechTranscriptionEvent) {
        handlers.last?(event)
    }
}
