import AgentKit
import AppKit
import SwiftUI
import TermindApplication
import TermindPresentation
import Testing

@testable import Termind

@Suite @MainActor
struct UserInputSpeechLayoutTests {
    @Test(arguments: [false, true])
    func recordingAndFinalizationReserveSpaceForBothControls(recording: Bool) {
        let controls = UserInputSpeechControls(
            isActive: true, isRecording: recording, canStart: false, start: {}, cancel: {}, stop: {})
        let host = NSHostingController(rootView: controls)
        let size = host.view.fittingSize
        // Two independent actions must keep their hit areas while leaving room for the answer.
        #expect(size.width >= 64 && size.width <= 96)
        #expect(size.height >= 32 && size.height <= 44)
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["TERMIND_ASSISTANT_SCREENSHOTS"] == "1"),
        arguments: [false, true])
    func captureSubmitAndContinueButtonStates(isDark: Bool) throws {
        let content = VStack(spacing: 16) {
            ForEach([true, false], id: \.self) { enabled in
                HStack(spacing: 12) {
                    Button(AppStrings.Common.submit.swiftUIKey) {}
                        .transcriptProminentButtonStyle()
                        .disabled(!enabled)
                    Button(AppStrings.Common.next.swiftUIKey) {}
                        .transcriptProminentButtonStyle()
                        .disabled(!enabled)
                    Button(AppStrings.Common.continue.swiftUIKey) {}
                        .transcriptProminentButtonStyle()
                        .disabled(!enabled)
                }
            }
        }
        .padding(20)
        .background(.background)
        .environment(\.colorScheme, isDark ? .dark : .light)
        let host = NSHostingController(rootView: content)
        host.view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        host.view.frame = NSRect(origin: .zero, size: host.view.fittingSize)
        host.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(png, named: "question-button-states-\(isDark).png")
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["TERMIND_ASSISTANT_SCREENSHOTS"] == "1"),
        arguments: ["en", "zh-Hans", "zh-Hant"], [360.0, 680.0])
    func captureAnswerFieldsAcrossSizesAndSpeechStates(language: String, width: Double) async throws {
        let service = DesktopQuestionSpeechService()
        let speech = SpeechTranscriptionCoordinator(service: service)
        let app = AppModel(hosts: HostLibraryModel(), speechTranscription: speech)
        for custom in [false, true] {
            let conversation = ConversationModel()
            let request = AgentUserInputRequest(
                questions: [
                    AgentUserQuestion(
                        id: "answer", prompt: "Where should this run?",
                        kind: custom
                            ? .choice(AgentUserInputChoice(options: [AgentUserInputOption(id: "a", label: "Staging")]))
                            : .text)
                ]
                    + (custom
                        ? [
                            AgentUserQuestion(id: "second", prompt: "Second question", kind: .text),
                            AgentUserQuestion(id: "third", prompt: "Third question", kind: .text),
                        ] : []))
            conversation.present(request)
            conversation.setUserInputCustomAnswer("Existing answer", for: "answer")
            for phase in ["idle", "recording", "transcribing"] {
                let session = UserInputSpeechSession()
                if phase != "idle" {
                    session.start(coordinator: speech, conversation: conversation) {}
                    for _ in 0..<100 {
                        if session.isRecording { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    try #require(session.isRecording)
                }
                if phase == "transcribing" { session.stop() }
                let content = AgentUserInputCard(
                    request: request, conversation: conversation, isCompact: width < 400,
                    interaction: UserInputInteractionModel(speech: session)
                )
                .environment(app)
                .environment(\.locale, Locale(identifier: language))
                .padding(16)
                .frame(width: width)
                .background(.background)
                let host = NSHostingController(rootView: content)
                let size = host.view.fittingSize
                #expect(abs(size.width - width) < 0.5)
                #expect(size.height > 80 && size.height < 360)
                host.view.frame = NSRect(origin: .zero, size: size)
                host.view.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                Attachment.record(png, named: "question-mac-\(language)-\(Int(width))-\(custom)-\(phase).png")
                session.cancel()
            }
            conversation.cancelUserInput()
        }
    }
}

@MainActor
private final class DesktopQuestionSpeechService: SpeechTranscriptionService {
    func requestAuthorization() async throws {}
    func start(locale: Locale, eventHandler: @escaping @MainActor (SpeechTranscriptionEvent) -> Void) throws {}
    func finish() {}
    func cancel() {}
}
