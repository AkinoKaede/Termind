import Foundation
import Testing

@testable import Termind

private actor CommandComposerRequestRecorder {
    private(set) var requests: [AgentModelRequest] = []

    func append(_ request: AgentModelRequest) {
        requests.append(request)
    }
}

private struct CommandComposerModelStub: AgentModelCompleting {
    var events: [AgentModelStreamEvent]
    var recorder: CommandComposerRequestRecorder?

    func complete(
        _ request: AgentModelRequest
    ) async throws -> [AgentModelStreamEvent] {
        await recorder?.append(request)
        return events
    }
}

@Suite
struct CommandComposerServiceTests {
    @Test
    func sendsOnlyNarrowContextWithoutTools() async throws {
        let recorder = CommandComposerRequestRecorder()
        let model = CommandComposerModelStub(
            events: [
                .textDelta(#"{"command":"ls -la"}"#),
                .finished(.completed),
            ],
            recorder: recorder
        )
        let context = CommandComposerContext(
            draft: "show hidden files", shell: "zsh", cwd: "/srv/app"
        )

        let command = try await CommandComposerService().compose(
            context: context, model: model
        )
        let request = try #require(await recorder.requests.first)
        let message = try #require(request.messages.only)
        let encoded = try #require(message.text.data(using: .utf8))

        #expect(command == "ls -la")
        #expect(request.tools.isEmpty)
        #expect(try JSONDecoder().decode(CommandComposerContext.self, from: encoded) == context)
        #expect(!message.text.localizedCaseInsensitiveContains("history"))
        #expect(!message.text.contains("hostname"))
        #expect(!message.text.contains("exitStatus"))
    }

    @Test
    func authoritativeSnapshotReplacesStreamingDeltas() async throws {
        let model = CommandComposerModelStub(events: [
            .textDelta(#"{"command":"wrong"}"#),
            .textSnapshot(#"{"command":"printf '%s\\n' hello"}"#),
            .finished(.completed),
        ])

        let command = try await CommandComposerService().compose(
            context: .init(draft: "print hello", shell: "bash", cwd: "/tmp"),
            model: model
        )

        #expect(command == #"printf '%s\n' hello"#)
    }

    @Test(arguments: [
        "",
        #"{"command":""}"#,
        #"{"command":"ls","extra":true}"#,
        "```json\n{\"command\":\"ls\"}\n```",
        #"{"command":" ls"}"#,
        #"{"command":"ls "}"#,
        "{\"command\":\"echo first\\nsecond\"}",
        "{\"command\":\"echo \\u0085 second\"}",
    ])
    func rejectsMalformedOrUnsafeResponses(_ response: String) async {
        let model = CommandComposerModelStub(events: [
            .textSnapshot(response), .finished(.completed),
        ])

        await #expect(throws: CommandComposerError.self) {
            try await CommandComposerService().compose(
                context: .init(draft: "list", shell: "bash", cwd: "/tmp"),
                model: model
            )
        }
    }

    @Test
    func rejectsToolCallsTruncationAndOversizedInput() async {
        let context = CommandComposerContext(draft: "list", shell: "bash", cwd: "/tmp")
        let toolModel = CommandComposerModelStub(events: [
            .toolCallDelta(id: "1", name: "ssh_exec", arguments: "{}"),
            .finished(.toolCalls),
        ])
        let doneTerminatedModel = CommandComposerModelStub(events: [
            .textSnapshot(#"{"command":"ls"}"#),
        ])
        let truncatedModel = CommandComposerModelStub(events: [
            .textSnapshot(#"{"command":"ls"}"#), .finished(.length),
        ])

        await #expect(throws: CommandComposerError.self) {
            try await CommandComposerService().compose(context: context, model: toolModel)
        }
        await #expect(throws: CommandComposerError.self) {
            try await CommandComposerService().compose(context: context, model: truncatedModel)
        }
        let doneTerminatedCommand = try? await CommandComposerService().compose(
            context: context, model: doneTerminatedModel
        )
        #expect(doneTerminatedCommand == "ls")
        await #expect(throws: CommandComposerError.self) {
            try await CommandComposerService().compose(
                context: .init(
                    draft: String(repeating: "x", count: 8 * 1024),
                    shell: "bash", cwd: "/tmp"
                ),
                model: CommandComposerModelStub(events: [])
            )
        }
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
