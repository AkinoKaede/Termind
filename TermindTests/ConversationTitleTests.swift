import Foundation
import Testing

@testable import Termind

private actor ConversationTitleRequestRecorder {
    private(set) var requests: [AgentModelRequest] = []

    func append(_ request: AgentModelRequest) {
        requests.append(request)
    }
}

private struct ConversationTitleModelStub: AgentModelCompleting {
    var events: [AgentModelStreamEvent]
    var recorder: ConversationTitleRequestRecorder?

    func complete(
        _ request: AgentModelRequest
    ) async throws -> [AgentModelStreamEvent] {
        await recorder?.append(request)
        return events
    }
}

@Suite
struct ConversationTitleServiceTests {
    @Test
    func summarizesTheOpeningExchangeWithoutTools() async throws {
        let recorder = ConversationTitleRequestRecorder()
        let model = ConversationTitleModelStub(
            events: [
                .textDelta(#"{"title":"Root volume filling up"}"#),
                .finished(.completed),
            ],
            recorder: recorder
        )

        let title = try await ConversationTitleService().summarize(
            context: ConversationTitleContext(
                firstUserMessage: "Root is at 99%. What is eating the space?",
                firstAssistantMessage: "Start with du -sh /var/*."
            ),
            model: model
        )

        #expect(title == "Root volume filling up")
        let requests = await recorder.requests
        #expect(requests.count == 1)
        // Naming a conversation may never act on it.
        #expect(requests.first?.tools.isEmpty == true)
        #expect(requests.first?.messages.count == 1)
        #expect(requests.first?.messages.first?.text.contains("Root is at 99%") == true)
    }

    @Test
    func aToolCallIsNotAnAnswerToThisQuestion() async {
        let model = ConversationTitleModelStub(
            events: [
                .toolCallDelta(id: "1", name: "run", arguments: "{}"),
                .finished(.toolCalls),
            ],
            recorder: nil
        )

        await #expect(throws: ConversationTitleError.self) {
            try await ConversationTitleService().summarize(
                context: ConversationTitleContext(
                    firstUserMessage: "hello", firstAssistantMessage: "hi"
                ),
                model: model
            )
        }
    }

    @Test
    func longMessagesAreClampedRatherThanRefused() async throws {
        let recorder = ConversationTitleRequestRecorder()
        let model = ConversationTitleModelStub(
            events: [.textSnapshot(#"{"title":"Long log"}"#), .finished(.completed)],
            recorder: recorder
        )

        let title = try await ConversationTitleService().summarize(
            context: ConversationTitleContext(
                firstUserMessage: String(repeating: "a", count: 40_000),
                firstAssistantMessage: String(repeating: "b", count: 40_000)
            ),
            model: model
        )

        #expect(title == "Long log")
        let payload = await recorder.requests.first?.messages.first?.text ?? ""
        #expect(payload.utf8.count <= ConversationTitleService.maximumPayloadBytes)
    }

    @Test
    func parseRejectsAnythingThatIsNotOneShortLine() {
        let rejected = [
            "",
            "Root volume filling up",
            #"{"title":""}"#,
            #"{"title":"  "}"#,
            #"{"title":"two\nlines"}"#,
            "{\"title\":\"bell\u{7}\"}",
            #"{"title":"ok","extra":"no"}"#,
            #"{"name":"ok"}"#,
        ]

        for text in rejected {
            #expect(throws: ConversationTitleError.self) {
                try ConversationTitleService.parse(text)
            }
        }
    }

    /// The one thing repaired rather than rejected. Seven words instead of six
    /// is still an answer to this question; two keys is not.
    @Test
    func anOverLongTitleIsTruncated() throws {
        let long = String(repeating: "x", count: 200)
        let title = try ConversationTitleService.parse(#"{"title":"\#(long)"}"#)

        #expect(title.count == ConversationTitleService.maximumTitleCharacters + 1)
        #expect(title.hasSuffix("…"))
    }

    @Test
    func surroundingWhitespaceIsTrimmedFromBothTheReplyAndTheTitle() throws {
        let title = try ConversationTitleService.parse("\n  {\"title\":\"  Disk usage  \"}  \n")

        #expect(title == "Disk usage")
    }
}
