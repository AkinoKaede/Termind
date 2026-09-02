import AgentKit
import AgentKitScrubber
import Foundation
import Testing

@testable import Termind

@Suite
struct WebSearchTests {
    @Test
    func scrubberSearchToolIsLocallyReadOnlyAndRequiresAQuery() async throws {
        let tool = WebSearchTool(web: stubClient())
        #expect(tool.descriptor.name == "web_search")
        #expect(tool.descriptor.target == .network)
        #expect(tool.descriptor.safety == .locallyReadOnly)
        #expect(try await tool.preflight(invocation(query: "swift")).safety == .locallyReadOnly)

        await #expect(throws: AgentToolError.self) {
            try await tool.preflight(AgentToolInvocation(
                runID: UUID(),
                call: AgentToolCall(id: "1", name: "web_search", arguments: .object([:]))
            ))
        }
    }

    @Test
    func localSearchToolIsRegisteredOnlyWhenSelected() {
        let without = AgentToolCatalog.registry(builtIn: .init(web: stubClient()))
            .descriptors
        let with = AgentToolCatalog.registry(
            builtIn: .init(web: stubClient(), search: stubClient())
        ).descriptors
        #expect(!without.contains { $0.name == "web_search" })
        #expect(with.contains { $0.name == "web_search" })
    }

    @Test
    func protocolSupportIsSeparateFromTheModelGuess() {
        var provider = ModelProvider(name: "Gateway")
        #expect(!provider.acceptsNativeWebSearchTool)
        provider.usesResponsesAPI = true
        #expect(provider.acceptsNativeWebSearchTool)

        var anthropic = ModelProvider(name: "Anthropic")
        anthropic.kind = .anthropic
        #expect(anthropic.acceptsNativeWebSearchTool)

        var google = ModelProvider(name: "Google")
        google.kind = .google
        #expect(google.acceptsNativeWebSearchTool)
    }

    @Test
    func recognisedProviderModelsStillSupportNativeSearch() {
        var model = AIModel(id: "gpt-5.4")
        model.abilities = [.toolCall, .webSearch]
        var provider = ModelProvider(name: "OpenAI")
        provider.usesResponsesAPI = true
        #expect(provider.supportsNativeWebSearch(model: model))
    }

    @Test @MainActor
    func providerNativeSearchMakesACardButNotATranscriptTurn() {
        let conversation = ConversationModel()
        let invocation = invocation(query: "swift 6")
        let descriptor = AgentToolDescriptor(
            name: "web_search", summary: "Web search run by the model provider.",
            inputSchema: .object(["type": .string("object")]),
            target: .network, safety: .locallyReadOnly
        )
        conversation.handle(.toolProposed(invocation, descriptor))
        conversation.handle(.toolFinished(invocation, AgentToolResult(
            callID: invocation.call.id, content: "[]",
            metadata: [AgentToolResult.providerNativeKey: .bool(true)]
        )))

        #expect(conversation.toolCards.count == 1)
        #expect(conversation.transcript.isEmpty)
        #expect(conversation.pendingPriorMessages.isEmpty)
    }

    @Test @MainActor
    func ordinarySearchResultsStillEnterTheTranscript() {
        let conversation = ConversationModel()
        let invocation = invocation(query: "swift 6")
        let descriptor = AgentToolDescriptor(
            name: "web_search", summary: "Search the public web.",
            inputSchema: .object(["type": .string("object")]),
            target: .network, safety: .locallyReadOnly
        )
        conversation.handle(.toolProposed(invocation, descriptor))
        conversation.handle(.toolFinished(invocation, AgentToolResult(
            callID: invocation.call.id, content: "<untrusted-data>\n[]\n</untrusted-data>"
        )))
        #expect(conversation.transcript.count == 1)
        #expect(conversation.transcript[0].role == .tool)
    }

    @Test
    func orphanedProviderSearchResultsAreDroppedFromHistory() {
        let history: [AgentTranscriptMessage] = [
            AgentTranscriptMessage(role: .user, text: "look it up"),
            AgentTranscriptMessage(
                role: .assistant, text: "",
                toolCalls: [AgentToolCall(id: "call-1", name: "ssh_exec", arguments: .object([:]))]
            ),
            AgentTranscriptMessage(
                role: .tool, text: "ok", toolCallID: "call-1", toolName: "ssh_exec"
            ),
            AgentTranscriptMessage(
                role: .tool, text: "[]",
                toolCallID: "provider-web-search-11328F4A", toolName: "web_search"
            ),
        ]
        let repaired = AgentOrphanedToolResultRepair.apply(history)
        #expect(repaired.count == 3)
        #expect(!repaired.contains { $0.toolCallID?.hasPrefix("provider-web-search") == true })
    }

    private func stubClient() -> ScrubberWebClient {
        ScrubberWebClient(
            document: { _ in throw AgentWebError.emptyDocument },
            search: { _, _ in [] }
        )
    }

    private func invocation(query: String) -> AgentToolInvocation {
        AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(
                id: "call-1", name: "web_search",
                arguments: .object(["query": .string(query)])
            )
        )
    }
}
