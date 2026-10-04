import AgentKit
import Foundation
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct TerminalSuggestToolTests {
    @Test
    func suggestionAcceptsOnlyACommandAndReturnsNoExplanation() async throws {
        let tool = TerminalSuggestTool()
        let arguments = AgentJSONValue.object(["command": .string("pwd")])
        try AgentJSONSchemaValidator.validate(arguments, against: tool.descriptor.inputSchema)
        #expect(
            throws: (any Error).self,
            performing: {
                try AgentJSONSchemaValidator.validate(
                    .object(["command": .string("pwd"), "explanation": .string("Show the directory.")]),
                    against: tool.descriptor.inputSchema
                )
            }
        )
        let invocation = AgentToolInvocation(
            runID: UUID(), call: .init(id: "suggestion", name: "terminal_suggest", arguments: arguments)
        )
        let context = AgentToolExecutionContext(
            runID: invocation.runID, userIntent: "Suggest a command",
            secretBroker: SecretBroker(), userInteraction: UnavailableAgentUserInteraction(),
            preflightMetadata: [:], authorize: { _ in .allow }
        )
        let result = try await tool.execute(invocation, context: context)
        let raw = try #require(result.untrustedPayload)
        let payload = try #require(AgentJSONValue.decode(Data(raw.utf8)).objectValue)
        #expect(payload["command"] == .string("pwd"))
        #expect(payload["requires_user_action"] == .bool(true))
        #expect(payload["risk"]?.stringValue?.isEmpty == false)
        #expect(payload["explanation"] == nil)
    }

    @Test
    func legacyExplanationIsNotPresented() {
        let items = TerminalSuggestTool.present(
            AgentToolDetailInput(
                result: .object(["command": .string("pwd"), "explanation": .string("Legacy result explanation")]),
                arguments: ["command": .string("pwd"), "explanation": .string("Legacy argument explanation")],
                locale: Locale(identifier: "en")
            )
        )
        #expect(items.contains(.text(.init(title: "Command", text: "pwd", style: .monospaced))))
        #expect(items.contains(.message("Requires user action", .warning)))
        #expect(!String(describing: items).contains("Legacy"))
    }
}
