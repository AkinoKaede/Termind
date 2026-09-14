import AgentKit
import AgentKitScrubber
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite
struct ScrubberWebClientTests {
    @Test(arguments: [
        "https://example.com/page", "http://127.0.0.1:8080/private",
        "http://router.local/status",
    ])
    func acceptsPublicAndPrivateHTTPPages(_ rawURL: String) throws {
        #expect(try AgentWebAddress.validated(rawURL).absoluteString == rawURL)
    }

    @Test(arguments: [
        "file:///etc/passwd", "ssh://example.com", "https://user:pass@example.com/",
        "not a URL",
    ])
    func rejectsNonWebAndCredentialBearingURLs(_ rawURL: String) {
        #expect(throws: AgentWebError.self) {
            try AgentWebAddress.validated(rawURL)
        }
    }

    @Test
    func fetchDefaultsToMarkdownAndCanReturnOriginalHTML() async throws {
        let client = fixtureClient()
        let tool = FetchTool(web: client)

        let markdown = try await tool.execute(
            invocation("fetch", ["url": .string("http://router.local/")]),
            context: context()
        )
        #expect(markdown.content.contains("\"format\":\"markdown\""))
        #expect(markdown.content.contains("# Readable"))
        #expect(!markdown.content.contains("raw-marker"))

        let original = try await tool.execute(
            invocation(
                "fetch",
                [
                    "url": .string("http://router.local/"), "format": .string("original"),
                ]),
            context: context()
        )
        #expect(original.content.contains("\"format\":\"original\""))
        #expect(original.content.contains("raw-marker"))
        #expect(!original.content.contains("# Readable"))
    }

    @Test
    func fetchBoundsEitherRepresentationAt256KiB() async throws {
        let oversized = String(repeating: "x", count: 256 * 1_024 + 100)
        let client = ScrubberWebClient(
            document: { url in
                AgentWebDocument(
                    title: "Large", url: url, markdown: oversized, original: oversized
                )
            },
            search: { _, _ in [] }
        )
        let result = try await FetchTool(web: client).execute(
            invocation("fetch", ["url": .string("https://example.com")]),
            context: context()
        )
        #expect(result.isTruncated)
        #expect(result.content.contains("\"truncated\":true"))
    }

    @Test
    func webSearchReturnsBoundedMarkdownAndEngine() async throws {
        let oversized = String(repeating: "m", count: 32 * 1_024 + 10)
        let client = ScrubberWebClient(
            document: { _ in throw AgentWebError.emptyDocument },
            search: { query, count in
                #expect(query == "swift concurrency")
                #expect(count == 5)
                return [
                    AgentWebDocument(
                        engine: "google", title: "Result",
                        url: URL(string: "https://example.com/result")!,
                        markdown: oversized, original: "<html></html>"
                    )
                ]
            }
        )
        let result = try await WebSearchTool(web: client).execute(
            invocation("web_search", ["query": .string("swift concurrency")]),
            context: context()
        )
        #expect(result.isTruncated)
        #expect(result.content.contains("\"engine\":\"google\""))
        #expect(result.content.contains("\"markdown\":"))
        #expect(!result.content.contains("<html>"))
    }

    @Test
    func fetchPreflightNeverEscalatesPrivateHTTP() async throws {
        let invocation = invocation(
            "fetch",
            [
                "url": .string("http://192.168.1.1/admin")
            ])
        let preflight = try await FetchTool(web: fixtureClient()).preflight(invocation)
        #expect(preflight.approvalPolicy == .approve)
        #expect(preflight.reasons.isEmpty)
    }

    private func fixtureClient() -> ScrubberWebClient {
        ScrubberWebClient(
            document: { url in
                AgentWebDocument(
                    title: "Router", url: url, markdown: "# Readable",
                    original: "<html><body>raw-marker</body></html>"
                )
            },
            search: { _, _ in [] }
        )
    }

    private func invocation(
        _ name: String, _ arguments: [String: AgentJSONValue]
    ) -> AgentToolInvocation {
        AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(id: "call-1", name: name, arguments: .object(arguments))
        )
    }

    private func context() -> AgentToolExecutionContext {
        AgentToolExecutionContext(
            runID: UUID(), userIntent: "read the page", secretBroker: SecretBroker(),
            userInteraction: UnavailableAgentUserInteraction(),
            preflightMetadata: [:], authorize: { _ in .allow }
        )
    }
}
