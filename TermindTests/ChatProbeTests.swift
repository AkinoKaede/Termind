import Foundation
import Testing

@testable import Termind

struct ChatProbeTests {
    @Test
    func responsesProbeUsesInputItemList() throws {
        var provider = ModelProvider(name: "OpenAI")
        provider.usesResponsesAPI = true

        let data = try ChatProbe.body(for: AIModel(id: "gpt-5.6-sol"), on: provider)
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let input = try #require(root["input"] as? [[String: Any]])
        let message = try #require(input.first)
        let content = try #require(message["content"] as? [[String: Any]])
        let text = try #require(content.first)

        #expect(root["model"] as? String == "gpt-5.6-sol")
        #expect(message["type"] as? String == "message")
        #expect(message["role"] as? String == "user")
        #expect(text["type"] as? String == "input_text")
        #expect(text["text"] as? String == ChatProbe.prompt)
    }

    @Test
    func queuedTestResultIsVisibleAsWaiting() {
        let result = ModelListEditor.TestResult.queued

        #expect(result.message == "Waiting…")
        #expect(result.symbol == "hourglass")
        #expect(!result.isSuccess)
    }
}
