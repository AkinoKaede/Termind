import AgentKit
import SwiftUI
import TermindApplication
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileUserInputSpeechLayoutTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [320.0, 768.0])
    func answerFieldsFitPhoneAndPadWhileRecordingAndTranscribing(language: String, width: Double) async throws {
        let app = try MobileAppModel(inMemory: true)
        let service = MobileQuestionSpeechService()
        let speech = SpeechTranscriptionCoordinator(service: service)
        for custom in [false, true] {
            let conversation = ConversationModel()
            conversation.present(
                AgentUserInputRequest(
                    questions: [
                        AgentUserQuestion(
                            id: "answer", prompt: "Where should this run?",
                            kind: custom
                                ? .choice(
                                    AgentUserInputChoice(options: [AgentUserInputOption(id: "a", label: "Staging")]))
                                : .text)
                    ]
                        + (custom
                            ? [
                                AgentUserQuestion(id: "second", prompt: "Second question", kind: .text),
                                AgentUserQuestion(id: "third", prompt: "Third question", kind: .text),
                            ] : [])))
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
                let content = MobileAssistantInteraction(
                    conversation: conversation, hosts: app.library, speech: speech, speechSession: session
                )
                .environment(\.locale, Locale(identifier: language))
                .environment(\.dynamicTypeSize, .large)
                .environment(\.horizontalSizeClass, width < 400 ? .compact : .regular)
                .padding(12)
                .frame(width: width)
                .background(.background)
                let host = UIHostingController(rootView: content)
                host.safeAreaRegions = []
                let size = host.sizeThatFits(in: CGSize(width: width, height: 600))
                #expect(abs(size.width - width) < 0.5)
                #expect(size.height > 80 && size.height < 600)
                // A non-key window lets UIKit-backed text fields render, without
                // taking over the process-wide presentation/key-window state.
                let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(origin: .zero, size: size)
                window.rootViewController = host
                window.isHidden = false
                defer {
                    window.isHidden = true
                    window.rootViewController = nil
                }
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                let image = UIGraphicsImageRenderer(size: size).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let png = try #require(image.pngData())
                Attachment.record(png, named: "question-ios-\(language)-\(Int(width))-\(custom)-\(phase).png")
                session.cancel()
            }
            conversation.cancelUserInput()
        }
    }
}

@MainActor
private final class MobileQuestionSpeechService: SpeechTranscriptionService {
    func requestAuthorization() async throws {}
    func start(locale: Locale, eventHandler: @escaping @MainActor (SpeechTranscriptionEvent) -> Void) throws {}
    func finish() {}
    func cancel() {}
}
