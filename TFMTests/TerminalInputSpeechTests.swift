// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import Testing

@testable import Termind

@Suite @MainActor
struct TerminalInputSpeechTests {
    @Test(arguments: TerminalInputMode.allCases)
    func speechAppendsToTheCurrentDraftWithoutSubmitting(mode: TerminalInputMode) async throws {
        let model = TerminalInputAreaModel()
        let service = TerminalInputSpeechService()
        let transcription = SpeechTranscriptionCoordinator(service: service)
        defer { model.close() }
        model.mode = mode
        model.draft = "Original"
        model.startTranscription(using: transcription) {
            Issue.record("Stopping recording without Send must only append the transcript")
        }
        try await wait { transcription.phase == .recording }
        #expect(model.isTranscribing)
        model.startTranscription(using: transcription)
        #expect(service.handlers.count == 1)
        service.emit(.partial("Partial speech"))
        #expect(model.draft == "Original")
        model.draft = "Manual edit"
        #expect(model.isTranscribing)
        #expect(!model.submit { _ in Issue.record("Recording must never submit") })
        model.stopTranscription()
        #expect(transcription.phase == .transcribing)
        #expect(service.finishCount == 1)
        #expect(!model.submit { _ in Issue.record("Pending transcription must never submit") })
        service.emit(.final("  Final speech  "))
        #expect(model.draft == "Manual edit Final speech")
        #expect(model.mode == mode)
        #expect(!model.isTranscribing)
        #expect(model.focusRequest > 0)
    }

    @Test(arguments: ["hide", "mode", "close", "pending"])
    func cancellationPreservesTheDraftAndDiscardsLateSpeech(reason: String) async throws {
        let model = TerminalInputAreaModel()
        let service = TerminalInputSpeechService()
        let transcription = SpeechTranscriptionCoordinator(service: service)
        defer { model.close() }
        model.draft = "keep this"
        model.startTranscription(using: transcription)
        try await wait { transcription.phase == .recording }
        let stale = try #require(service.handlers.first)
        switch reason {
        case "mode": model.mode = .commandGenerator
        case "close": model.close()
        case "pending":
            model.stopTranscription()
            model.cancelTranscription()
        default: model.cancelTranscription()
        }
        #expect(!model.isTranscribing)
        #expect(transcription.ownerID == nil)
        stale(.final("stale text"))
        #expect(model.draft == (reason == "close" ? "" : "keep this"))
        #expect(service.cancelCount == 1)

        model.startTranscription(using: transcription)
        try await wait { transcription.phase == .recording }
        stale(.final("still stale"))
        #expect(model.isTranscribing)
        service.emit(.final("new text"))
        #expect(model.draft == (reason == "close" ? "new text" : "keep this new text"))
    }

    @Test(arguments: [
        SpeechTranscriptionFailure.Code.microphonePermissionDenied, .speechPermissionDenied,
        .recognizerUnavailable,
    ])
    func permissionAndAvailabilityFailuresPreserveInputAndAllowRetry(
        code: SpeechTranscriptionFailure.Code
    ) async throws {
        let model = TerminalInputAreaModel()
        let service = TerminalInputSpeechService()
        service.authorizationError = SpeechTranscriptionFailure(code)
        let transcription = SpeechTranscriptionCoordinator(service: service)
        defer { model.close() }
        model.draft = "keep this"
        model.startTranscription(using: transcription)
        try await wait { model.transcriptionError != nil && !model.isTranscribing }
        #expect(model.transcriptionError?.code == code)
        #expect(model.draft == "keep this")
        #expect(service.handlers.isEmpty)
        model.dismissTranscriptionError()
        #expect(model.transcriptionError == nil)
        service.authorizationError = nil
        model.startTranscription(using: transcription)
        try await wait { transcription.phase == .recording }
        service.emit(.final("retry"))
        #expect(model.draft == "keep this retry")
    }

    @Test
    func cancellingDuringAuthorizationCannotStartRecordingOrInterfereWithAnotherOwner() async throws {
        let model = TerminalInputAreaModel()
        let service = TerminalInputSpeechService()
        let transcription = SpeechTranscriptionCoordinator(service: service)
        var authorization: CheckedContinuation<Void, Never>?
        service.authorizationHandler = {
            await withCheckedContinuation { authorization = $0 }
        }
        model.startTranscription(using: transcription)
        try await wait { authorization != nil }
        #expect(model.isTranscribing && transcription.isRequestingAuthorization)
        model.cancelTranscription()
        service.authorizationHandler = nil
        let chatOwner = UUID()
        #expect(await transcription.start(ownerID: chatOwner) { _, _ in })
        authorization?.resume()
        try await Task.sleep(for: .milliseconds(20))
        #expect(service.handlers.count == 1)
        #expect(transcription.ownerID == chatOwner && transcription.phase == .recording)
        model.startTranscription(using: transcription)
        model.close()
        #expect(!model.isTranscribing)
        #expect(transcription.ownerID == chatOwner)
        transcription.cancelAll()
    }

    @Test
    func recordingBlocksGenerationAndDoesNotSubmitWithoutAHandler() async throws {
        let model = TerminalInputAreaModel()
        let service = TerminalInputSpeechService()
        let transcription = SpeechTranscriptionCoordinator(service: service)
        defer { model.close() }
        model.mode = .commandGenerator
        model.draft = "request"
        model.startTranscription(using: transcription)
        try await wait { transcription.phase == .recording }
        let generator = SpeechBlockedGenerator()
        model.generate(
            context: .init(draft: model.draft, shell: "zsh", cwd: "/tmp"),
            using: generator, isCurrent: { true })
        #expect(!model.isGenerating && generator.calls == 0)
        transcription.stop(ownerID: model.transcriptionOwnerID, sendAfterTranscription: true)
        service.emit(.final("speech"))
        #expect(model.mode == .commandGenerator && model.draft == "request speech")
        #expect(!model.isGenerating && generator.calls == 0)
    }

    @Test(arguments: TerminalInputMode.allCases)
    func sendingDuringRecordingWaitsForTheFinalTranscriptAndPerformsTheCurrentActionOnce(
        mode: TerminalInputMode
    ) async throws {
        let model = TerminalInputAreaModel()
        let service = TerminalInputSpeechService()
        let transcription = SpeechTranscriptionCoordinator(service: service)
        let generator = SpeechBlockedGenerator()
        defer { model.close() }
        model.mode = mode
        model.draft = "Original"
        var requests: [String] = []
        var sent: [String] = []
        model.startTranscription(using: transcription) {
            #expect(!model.isTranscribing)
            requests.append(model.draft)
            switch model.mode {
            case .input:
                model.submit { sent.append($0) }
            case .commandGenerator:
                model.generate(
                    context: .init(draft: model.draft, shell: "", cwd: ""),
                    using: generator, isCurrent: { true })
            }
        }
        try await wait { transcription.phase == .recording }
        model.submitTranscription()
        model.submitTranscription()
        #expect(transcription.phase == .transcribing && service.finishCount == 1)
        #expect(requests.isEmpty && sent.isEmpty && generator.calls == 0)
        let completion = try #require(service.handlers.last)
        completion(.final(" recognized speech "))
        completion(.final("duplicate"))
        #expect(requests == ["Original recognized speech"])
        if mode == .input {
            #expect(sent == requests && model.draft.isEmpty)
            #expect(generator.calls == 0)
        } else {
            try await wait { !model.isGenerating }
            #expect(generator.calls == 1 && sent.isEmpty)
            #expect(model.mode == .input && model.draft == "pwd")
        }
    }

    @Test(arguments: ["cancel", "mode", "close", "failure", "empty"])
    func cancelledOrUnsuccessfulSpeechCannotPerformThePendingSend(outcome: String) async throws {
        let model = TerminalInputAreaModel()
        let service = TerminalInputSpeechService()
        let transcription = SpeechTranscriptionCoordinator(service: service)
        defer { model.close() }
        model.draft = "Keep this"
        var submitted = false
        model.startTranscription(using: transcription) { submitted = true }
        try await wait { transcription.phase == .recording }
        model.submitTranscription()
        let completion = try #require(service.handlers.last)
        switch outcome {
        case "mode": model.mode = .commandGenerator
        case "close": model.close()
        case "failure": completion(.failure(.init(.recognitionFailed)))
        case "empty": completion(.final(" \n "))
        default: model.cancelTranscription()
        }
        completion(.final("late speech"))
        #expect(!submitted && !model.isTranscribing)
        #expect(model.draft == (outcome == "close" ? "" : "Keep this"))
    }

    @Test
    func rejectedSendAfterSpeechPreservesTheCombinedDraftAndItsError() async throws {
        let model = TerminalInputAreaModel()
        let service = TerminalInputSpeechService()
        let transcription = SpeechTranscriptionCoordinator(service: service)
        defer { model.close() }
        model.draft = "Original"
        model.startTranscription(using: transcription) {
            #expect(!model.submit { _ in throw TerminalInputAreaError.unavailable })
        }
        try await wait { transcription.phase == .recording }
        model.submitTranscription()
        service.emit(.final("speech"))
        #expect(model.draft == "Original speech" && model.error != nil)
    }

    @Test(arguments: ["", "existing", "existing\n"])
    func speechAddsOnlyTheNecessarySeparator(draft: String) {
        let model = TerminalInputAreaModel()
        model.draft = draft
        model.applyTranscription(" \n ")
        #expect(model.draft == draft)
        model.applyTranscription("  words  ")
        #expect(model.draft == draft + (draft == "existing" ? " " : "") + "words")
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for transcription state")
    }
}

@MainActor
final class TerminalInputSpeechService: SpeechTranscriptionService {
    var authorizationError: SpeechTranscriptionFailure?
    var authorizationHandler: (@MainActor () async -> Void)?
    var handlers: [@MainActor (SpeechTranscriptionEvent) -> Void] = []
    var finishCount = 0
    var cancelCount = 0

    func requestAuthorization() async throws {
        await authorizationHandler?()
        if let authorizationError { throw authorizationError }
    }

    func start(locale: Locale, eventHandler: @escaping @MainActor (SpeechTranscriptionEvent) -> Void) throws {
        handlers.append(eventHandler)
    }

    func finish() { finishCount += 1 }
    func cancel() { cancelCount += 1 }
    func emit(_ event: SpeechTranscriptionEvent) { handlers.last?(event) }
}

@MainActor
private final class SpeechBlockedGenerator: CommandGenerating {
    var calls = 0
    func generate(_ context: CommandGeneratorContext) async throws -> String {
        calls += 1
        return "pwd"
    }
}
