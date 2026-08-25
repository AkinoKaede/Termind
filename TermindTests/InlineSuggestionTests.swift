import Foundation
import Testing

@testable import Termind

private struct InlineModel: AgentModelStreaming {
    var text: String

    func stream(
        _ request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(text))
            continuation.yield(.finished(.completed))
            continuation.finish()
        }
    }
}

@Suite
struct InlineSuggestionTests {
    @Test @MainActor
    func promptArrivingWhileConnectingIsRetainedUntilSessionIsLive() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: SettingsKey.inlineSuggestionsEnabled)
        defaults.set(true, forKey: SettingsKey.inlineSuggestionsEnabled)
        defer {
            if let previous {
                defaults.set(previous, forKey: SettingsKey.inlineSuggestionsEnabled)
            } else {
                defaults.removeObject(forKey: SettingsKey.inlineSuggestionsEnabled)
            }
        }

        let session = SSHSessionModel(hostID: UUID(), title: "Host")
        session.inlineSuggestionController = InlineSuggestionController(
            ai: AIStore(persistsSecrets: false)
        )
        session.status = .connecting
        session.receiveShellIntegrationEvent(.available(shell: "zsh"))
        session.receiveShellIntegrationEvent(
            .promptReady(cwd: "/srv/app", previousExitCode: 0)
        )

        #expect(session.hasPendingInlineSuggestionRequest)
        session.status = .connected
        session.resumePendingInlineSuggestion()
        #expect(!session.hasPendingInlineSuggestionRequest)
    }

    @Test
    func strictParserAcceptsOnlyOneControlFreeCommand() {
        #expect(InlineSuggestionService.parse(
            "{\"command\":\"git status\",\"explanation\":\"Inspect changes\"}"
        )?.command == "git status")
        #expect(
            InlineSuggestionService.parse("```json\n{\"command\":\"pwd\"}\n```")?.command
                == "pwd"
        )
        #expect(InlineSuggestionService.parse("Here: {\"command\":\"pwd\"}") == nil)
        #expect(InlineSuggestionService.parse("{\"command\":\"pwd\\nwhoami\"}") == nil)
        #expect(InlineSuggestionService.parse("{\"command\":\"pwd\\u001b[2J\"}") == nil)
        #expect(InlineSuggestionService.parse("{\"command\":\"\"}") == nil)
    }

    @Test
    func serviceUsesNoToolsAndReturnsParsedSuggestion() async {
        let service = InlineSuggestionService()
        let result = await service.suggest(
            for: UUID(),
            context: InlineSuggestionContext(
                hostName: "Production", hostAddress: "prod.example:22",
                cwd: "/srv/app", shell: "zsh", previousExitCode: 1,
                recentCommands: ["git status"]
            ),
            model: InlineModel(text: "{\"command\":\"git diff\"}")
        )
        #expect(result?.command == "git diff")
    }
}
