import Foundation
import SwiftUI
import TermindApplication
import Testing
import UIKit

@testable import TermindIOS

@Suite @MainActor
struct MobileAssistantSpeechTests {
    @Test(arguments: [320.0, 768.0], ["en", "zh-Hans", "zh-Hant"])
    func speechToolbarKeepsItsHeightOnPhoneAndPad(width: Double, language: String) throws {
        let app = try MobileAppModel(inMemory: true)
        let assistant = app.assistant.makeSceneModel()
        let composer = MobileAssistantComposer(model: assistant, conversation: assistant.conversation)
        for phase in [SpeechTranscriptionCoordinator.Phase.recording, .transcribing] {
            let controller = UIHostingController(
                rootView: composer.transcriptionControls(phase: phase)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.dynamicTypeSize, .large)
            )
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 200))
            #expect(abs(size.height - 48) < 0.5)
            #expect(size.width <= width)
        }
    }

    @Test(arguments: [false, true])
    func finalSpeechUsesTheComposerSendPathOnlyWhenRequested(shouldSend: Bool) async throws {
        let app = try MobileAppModel(inMemory: true)
        let assistant = app.assistant.makeSceneModel()
        let conversation = assistant.conversation
        conversation.composer.draft = "Existing"
        let composer = MobileAssistantComposer(model: assistant, conversation: conversation)
        let service = MobileComposerSpeechService()
        let speech = SpeechTranscriptionCoordinator(service: service)
        await speech.start(ownerID: conversation.id, completion: composer.applySpeechTranscript)

        speech.stop(ownerID: conversation.id, sendAfterTranscription: shouldSend)
        #expect(speech.phase == .transcribing)
        #expect(conversation.messages.isEmpty)
        #expect(conversation.composer.draft == "Existing")
        service.handler?(.final("Voice text"))

        #expect(speech.phase == .idle)
        if shouldSend {
            #expect(conversation.composer.draft.isEmpty)
            #expect(conversation.messages.map(\.text) == ["Existing Voice text"])
            #expect(assistant.library.selectedConversation === conversation)
            await conversation.stopAndWait()
        } else {
            #expect(conversation.composer.draft == "Existing Voice text")
            #expect(conversation.messages.isEmpty)
        }
    }

    @Test func speechSendExecutesComposerSlashCommands() throws {
        let app = try MobileAppModel(inMemory: true)
        let assistant = app.assistant.makeSceneModel()
        let conversation = assistant.conversation
        let composer = MobileAssistantComposer(model: assistant, conversation: conversation)

        composer.applySpeechTranscript("/plan", sendAfterTranscription: true)

        #expect(conversation.isPlanning)
        #expect(conversation.composer.draft.isEmpty)
        #expect(conversation.messages.isEmpty)
    }

    @Test(arguments: ["cancel", "empty", "switch"])
    func discardedSpeechDoesNotSendOrChangeDrafts(reason: String) async throws {
        let app = try MobileAppModel(inMemory: true)
        let assistant = app.assistant.makeSceneModel()
        let conversation = assistant.conversation
        conversation.composer.draft = "Original draft"
        let composer = MobileAssistantComposer(model: assistant, conversation: conversation)
        let service = MobileComposerSpeechService()
        let speech = SpeechTranscriptionCoordinator(service: service)
        await speech.start(ownerID: conversation.id, completion: composer.applySpeechTranscript)
        speech.stop(ownerID: conversation.id, sendAfterTranscription: true)

        if reason == "cancel" { speech.cancel(ownerID: conversation.id) }
        if reason == "switch" { assistant.newConversation() }
        service.handler?(.final(reason == "empty" ? "  \n" : "Late speech"))

        #expect(speech.phase == .idle)
        #expect(conversation.composer.draft == "Original draft")
        #expect(conversation.messages.isEmpty)
        #expect(assistant.conversation.messages.isEmpty)
        if reason == "switch" { #expect(assistant.conversation.composer.draft.isEmpty) }
    }
}

@MainActor
private final class MobileComposerSpeechService: SpeechTranscriptionService {
    var handler: (@MainActor (SpeechTranscriptionEvent) -> Void)?

    func requestAuthorization() async throws {}

    func start(locale: Locale, eventHandler: @escaping @MainActor (SpeechTranscriptionEvent) -> Void) throws {
        handler = eventHandler
    }

    func finish() {}
    func cancel() {}
}
