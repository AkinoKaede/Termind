import Foundation
import Testing

@testable import Termind

@Suite
struct WebSearchTests {

    // MARK: - Configuration

    @Test
    func keylessBackendIsConfiguredWithoutAKey() {
        let bing = WebSearchClient(backend: .bing)
        #expect(bing.isConfigured)
        #expect(!SearchBackend.bing.requiresAPIKey)

        let brave = WebSearchClient(backend: .brave)
        #expect(!brave.isConfigured)
        #expect(WebSearchClient(backend: .brave, apiKey: "token").isConfigured)
    }

    @Test
    func blankBaseURLResolvesToTheBackendDefault() {
        #expect(WebSearchClient(backend: .bing).resolvedURL == "https://www.bing.com/search")
        #expect(
            WebSearchClient(backend: .brave, apiKey: "k").resolvedURL
                == "https://api.search.brave.com/res/v1/web/search"
        )
        // A pasted URL very often carries a trailing slash, and every path
        // starts with one.
        #expect(
            WebSearchClient(backend: .tavily, baseURL: "https://proxy.example/", apiKey: "k")
                .resolvedURL == "https://proxy.example/search"
        )
    }

    // MARK: - Requests

    @Test
    func bingRequestLooksLikeSafariOnAMac() throws {
        let request = try WebSearchClient(backend: .bing, market: "en-US")
            .buildRequest(query: "swift concurrency", count: 5)

        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("https://www.bing.com/search?"))
        #expect(url.contains("q=swift%20concurrency") || url.contains("q=swift+concurrency"))
        #expect(request.httpMethod == "GET")

        let agent = try #require(request.value(forHTTPHeaderField: "User-Agent"))
        #expect(agent.contains("Macintosh"))
        #expect(agent.contains("Safari"))
        #expect(!agent.contains("Windows"))
        #expect(request.value(forHTTPHeaderField: "Accept-Language") != nil)
    }

    /// Verified against the live endpoint: with no `mkt`, Bing answers an
    /// anonymous request with a well-formed page of results for an unrelated
    /// query. The parse succeeds and the model is handed confident nonsense,
    /// so this parameter is load-bearing rather than a locale nicety.
    @Test
    func bingAlwaysCarriesAMarket() throws {
        let url = try #require(
            WebSearchClient(backend: .bing, market: "ja-JP")
                .buildRequest(query: "swift", count: 5).url?.absoluteString
        )
        #expect(url.contains("mkt=ja-JP"))

        // Derived per component, so a Mac with a language but no region still
        // searches in its own language rather than falling all the way to en-US.
        let market = WebSearchClient.preferredMarket
        #expect(market.contains("-"))
        #expect(market.split(separator: "-").count == 2)
    }

    @Test
    func keyedBackendsCarryTheirOwnAuthenticationHeader() throws {
        let brave = try WebSearchClient(backend: .brave, apiKey: "brave-token")
            .buildRequest(query: "q", count: 3)
        #expect(brave.value(forHTTPHeaderField: "X-Subscription-Token") == "brave-token")

        let tavily = try WebSearchClient(backend: .tavily, apiKey: "tavily-token")
            .buildRequest(query: "q", count: 3)
        #expect(tavily.value(forHTTPHeaderField: "Authorization") == "Bearer tavily-token")
        #expect(tavily.httpMethod == "POST")

        let exa = try WebSearchClient(backend: .exa, apiKey: "exa-token")
            .buildRequest(query: "q", count: 3)
        #expect(exa.value(forHTTPHeaderField: "x-api-key") == "exa-token")
    }

    @Test
    func exaAsksForCappedSnippetsRatherThanWholePages() throws {
        let request = try WebSearchClient(backend: .exa, apiKey: "k")
            .buildRequest(query: "q", count: 3)
        let payload = try #require(request.httpBody)
        let body = try #require(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        let contents = try #require(body["contents"] as? [String: Any])
        let text = try #require(contents["text"] as? [String: Any])
        // Reading a page in full stays `fetch`'s job, because that is the path
        // with address classification on the target.
        #expect(text["maxCharacters"] as? Int == 600)
    }

    // MARK: - Bing result page

    /// Trimmed from a real results page: the `b_algo` list item, the `h2 > a`
    /// title link, and the `b_algoSlug` snippet Kelivo's selectors read.
    private static let bingPage = """
        <html><body><ol id="b_results">
        <li class="b_algo b_algoBorder" data-bm="5">
          <h2><a href="https://swift.org/documentation/" h="ID=SERP,5">Swift Documentation</a></h2>
          <div class="b_caption">
            <p class="b_algoSlug">The <strong>Swift</strong> language guide &amp; reference.</p>
          </div>
        </li>
        <li class="b_algo">
          <h2><a href="https://www.bing.com/ck/a?!&amp;&amp;p=1&amp;u=a1aHR0cHM6Ly9leGFtcGxlLmNvbS9wYWdl">Example Page</a></h2>
          <div class="b_caption"><p>A second result.</p></div>
        </li>
        <li class="b_algo">
          <h2><a href="https://third.example/">Third</a></h2>
        </li>
        </ol></body></html>
        """

    @Test
    func bingPageYieldsTitleURLAndSnippet() {
        let results = WebSearchClient.bingResults(Self.bingPage, limit: 10)

        #expect(results.count == 3)
        #expect(results[0].title == "Swift Documentation")
        #expect(results[0].url == "https://swift.org/documentation/")
        // Tags stripped and entities decoded: the model reads this as prose,
        // and markup here costs tokens and invites confusion with instructions.
        #expect(results[0].snippet == "The Swift language guide & reference.")
        // A result with no snippet is still a result.
        #expect(results[2].title == "Third")
        #expect(results[2].snippet.isEmpty)
    }

    @Test
    func bingRedirectWrapperIsUnwrappedToTheRealURL() {
        let results = WebSearchClient.bingResults(Self.bingPage, limit: 10)
        // Left wrapped, the model would be handed a bing.com/ck/a URL that says
        // nothing about the source it is about to trust.
        #expect(results[1].url == "https://example.com/page")
        #expect(results[1].title == "Example Page")

        // Anything that is not the `u=a1<base64url>` form is left alone.
        let plain = "https://example.com/ck/a?u=not-base64"
        #expect(WebSearchClient.unwrapBingRedirect(plain) == plain)
    }

    @Test
    func bingResultsRespectTheRequestedCount() {
        #expect(WebSearchClient.bingResults(Self.bingPage, limit: 2).count == 2)
    }

    /// Bing writes its date separator as `&#0183;&#32;`, so a fixed list of
    /// named entities leaves raw numeric references in the text the model reads.
    @Test
    func numericEntitiesAreDecoded() {
        #expect(
            WebSearchClient.plainText("Jul 10, 2026&#0183;&#32;At Swift, we&#39;re open")
                == "Jul 10, 2026·\u{20}At Swift, we're open"
        )
        #expect(WebSearchClient.plainText("caf&#xe9; &amp; bar") == "café & bar")
        // A stray `&#` is left alone rather than swallowing the rest of the
        // text up to whatever semicolon comes next.
        #expect(WebSearchClient.plainText("A &# B; C") == "A &# B; C")
    }

    @Test
    func markupThatMovedYieldsNoResultsRatherThanFailing() {
        // The honest failure mode of scraping, and the reason a keyed backend
        // exists: an empty list reads to the model as "nothing found".
        #expect(WebSearchClient.bingResults("<html><body>no results here</body></html>", limit: 5).isEmpty)
    }

    // MARK: - DuckDuckGo result page

    private static let duckDuckGoPage = """
        <html><body>
        <div class="result results_links results_links_deep web-result ">
          <div class="result__body">
            <h2 class="result__title">
              <a class="result__a" href="https://nvd.nist.gov/vuln/detail/CVE-2024-3094">NVD - CVE-2024-3094</a>
            </h2>
            <a class="result__snippet" href="#">Malicious code was discovered in <b>xz</b> tarballs.</a>
          </div>
        </div>
        <div class="result results_links result--ad">
          <div class="result__body">
            <h2><a class="result__a" href="https://sponsor.example/buy">Sponsored Thing</a></h2>
            <a class="result__snippet" href="#">An advert.</a>
          </div>
        </div>
        <div class="result results_links results_links_deep web-result ">
          <div class="result__body">
            <h2><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FXZ&amp;rut=abc">XZ Utils backdoor</a></h2>
          </div>
        </div>
        </body></html>
        """

    @Test
    func duckDuckGoPageYieldsResultsAndSkipsAds() {
        let results = WebSearchClient.duckDuckGoResults(Self.duckDuckGoPage, limit: 10)

        #expect(results.count == 2)
        #expect(results[0].url == "https://nvd.nist.gov/vuln/detail/CVE-2024-3094")
        #expect(results[0].title == "NVD - CVE-2024-3094")
        #expect(results[0].snippet == "Malicious code was discovered in xz tarballs.")
        // An advert wears the same result markup, and handing one to the model
        // as a source is worse than returning one result fewer.
        #expect(!results.contains { $0.url.contains("sponsor.example") })
    }

    @Test
    func duckDuckGoRedirectWrapperIsUnwrapped() {
        let results = WebSearchClient.duckDuckGoResults(Self.duckDuckGoPage, limit: 10)
        #expect(results[1].url == "https://en.wikipedia.org/wiki/XZ")

        // Both shapes appear on the same endpoint, so a direct link must survive
        // the unwrapper untouched.
        let direct = "https://example.com/page"
        #expect(WebSearchClient.unwrapDuckDuckGoRedirect(direct) == direct)
    }

    @Test
    func duckDuckGoIsKeylessAndPostsItsQuery() throws {
        #expect(!SearchBackend.duckDuckGo.requiresAPIKey)
        let request = try WebSearchClient(backend: .duckDuckGo, market: "en-US")
            .buildRequest(query: "swift 6", count: 5)

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://html.duckduckgo.com/html/")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("q=swift"))
        // DuckDuckGo's region is Bing's market with its halves swapped.
        #expect(body.contains("kl=us-en"))
    }

    // MARK: - JSON backends

    @Test
    func braveResponseDecodesIntoResults() throws {
        let payload = Data("""
            {"web": {"results": [
              {"title": "Brave <strong>Hit</strong>", "url": "https://a.example",
               "description": "First &amp; best", "page_age": "2026-01-02T03:04:05Z"},
              {"title": "No URL"}
            ]}}
            """.utf8)

        let results = try WebSearchClient.decode(payload, backend: .brave, limit: 10)

        // The row with no URL is dropped rather than thrown on: one malformed
        // result should not lose the others.
        #expect(results.count == 1)
        #expect(results[0].title == "Brave Hit")
        #expect(results[0].snippet == "First & best")
        #expect(results[0].publishedAt != nil)
    }

    @Test
    func tavilyAndExaReadTheirOwnSnippetFields() throws {
        let tavily = try WebSearchClient.decode(
            Data("""
                {"results": [{"title": "T", "url": "https://t.example",
                 "content": "tavily snippet", "published_date": "2026-02-03"}]}
                """.utf8),
            backend: .tavily, limit: 10
        )
        #expect(tavily[0].snippet == "tavily snippet")
        #expect(tavily[0].publishedAt != nil)

        let exa = try WebSearchClient.decode(
            Data("""
                {"results": [{"title": "E", "url": "https://e.example", "text": "exa snippet"}]}
                """.utf8),
            backend: .exa, limit: 10
        )
        #expect(exa[0].snippet == "exa snippet")
    }

    @Test
    func nonJSONFromAKeyedBackendIsAnError() {
        #expect(throws: WebSearchError.self) {
            try WebSearchClient.decode(Data("<html>nope</html>".utf8), backend: .brave, limit: 5)
        }
    }

    // MARK: - The tool

    @Test
    func webSearchToolIsReadOnlyForAPublicBackend() async throws {
        let client = WebSearchClient(backend: .bing) { _ in .publicInternet }
        let tool = AgentBuiltInTools.webSearch(client)

        #expect(tool.descriptor.name == "web_search")
        #expect(tool.descriptor.target == .network)
        #expect(tool.descriptor.safety == .locallyReadOnly)

        let preflight = try await tool.preflight(invocation(query: "swift"))
        #expect(preflight.safety == .locallyReadOnly)
        #expect(preflight.reasons.isEmpty)
    }

    @Test
    func aBackendOnAPrivateNetworkAsksFirst() async throws {
        // Matching `fetch`: a search backend configured at a LAN address is
        // disclosed rather than silently reached, even though a query changes
        // nothing.
        let client = WebSearchClient(
            backend: .tavily, baseURL: "https://searx.lan", apiKey: "k"
        ) { _ in .restricted }
        let preflight = try await AgentBuiltInTools.webSearch(client)
            .preflight(invocation(query: "swift"))

        #expect(preflight.safety == .requiresAuthorization)
        #expect(preflight.reasons.count == 1)
        #expect(preflight.reasons[0].contains("https://searx.lan/search"))
    }

    @Test
    func aQueryIsRequired() async {
        let client = WebSearchClient(backend: .bing) { _ in .publicInternet }
        await #expect(throws: AgentToolError.self) {
            try await AgentBuiltInTools.webSearch(client).preflight(
                AgentToolInvocation(
                    runID: UUID(),
                    call: AgentToolCall(id: "1", name: "web_search", arguments: .object([:]))
                )
            )
        }
    }

    @Test @MainActor
    func theToolIsAbsentUntilABackendIsConfigured() {
        let hosts = AgentHostResolver(store: HostStore())
        let pool = AgentConnectionPool(
            configuration: { _ in throw AgentToolError.invalidHost },
            routeFingerprint: { _ in "" },
            openExec: { _ in throw AgentToolError.invalidHost },
            openSFTP: { _ in throw AgentToolError.invalidHost },
            sweepInterval: nil
        )

        let without = AgentBuiltInTools.make(hosts: hosts, connections: pool)
        #expect(!without.contains { $0.descriptor.name == "web_search" })

        // A model shown a tool it cannot use spends a turn discovering that.
        let with = AgentBuiltInTools.make(
            hosts: hosts, connections: pool, search: WebSearchClient(backend: .bing)
        )
        #expect(with.contains { $0.descriptor.name == "web_search" })
    }

    // MARK: - Provider-native search must stay out of the transcript

    /// The bug this pins produced, on the *second* request of a conversation:
    ///
    ///     400 No tool call found for function call output with call_id
    ///     provider-web-search-11328F4A-...
    ///
    /// A native search is a card, not a turn. The provider ran it inside its own
    /// assistant turn and never asked Termind for anything, so a transcript that
    /// carries it as a tool result replays a `function_call_output` matching no
    /// `function_call`. The first request looks fine because it is the one that
    /// puts the orphan into the history; the next one carries it and is rejected.
    @Test @MainActor
    func providerNativeSearchMakesACardButNotATranscriptTurn() {
        let conversation = ConversationModel()
        let invocation = self.invocation(query: "swift 6")
        let descriptor = AgentToolDescriptor(
            name: "web_search", summary: "Web search run by the model provider.",
            inputSchema: .object(["type": .string("object")]),
            target: .network, safety: .locallyReadOnly
        )

        conversation.handle(.toolProposed(invocation, descriptor))
        conversation.handle(.toolFinished(invocation, AgentToolResult(
            callID: invocation.call.id,
            content: "[]",
            metadata: [AgentToolResult.providerNativeKey: .bool(true)]
        )))

        #expect(conversation.toolCards.count == 1)
        #expect(conversation.transcript.isEmpty)
        // And so nothing reaches the next request's history.
        #expect(conversation.pendingPriorMessages.isEmpty)
    }

    /// The other half: an ordinary tool result still becomes a turn, or the
    /// model never learns what its own tool returned.
    @Test @MainActor
    func ordinaryToolResultsStillEnterTheTranscript() {
        let conversation = ConversationModel()
        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(
                id: "call-1", name: "web_search",
                arguments: .object(["query": .string("swift 6")])
            )
        )
        let descriptor = AgentToolDescriptor(
            name: "web_search", summary: "Search the public web.",
            inputSchema: .object(["type": .string("object")]),
            target: .network, safety: .locallyReadOnly
        )

        conversation.handle(.toolProposed(invocation, descriptor))
        conversation.handle(.toolFinished(invocation, AgentToolResult(
            callID: "call-1", content: "<untrusted-data>\n[]\n</untrusted-data>"
        )))

        #expect(conversation.transcript.count == 1)
        #expect(conversation.transcript[0].role == .tool)
        #expect(conversation.transcript[0].toolCallID == "call-1")
    }

    /// Repairs conversations already damaged by the bug above.
    ///
    /// A run persists its snapshot before the request goes out, so the failing
    /// request's own history was written to disk. Without this, an affected
    /// conversation keeps carrying the orphan forward and keeps being rejected,
    /// restart or not.
    @Test
    func orphanedToolResultsAreDroppedFromIncomingHistory() {
        let history: [AgentTranscriptMessage] = [
            AgentTranscriptMessage(role: .user, text: "look it up"),
            AgentTranscriptMessage(
                role: .assistant, text: "",
                toolCalls: [AgentToolCall(
                    id: "call-1", name: "ssh_exec", arguments: .object([:])
                )]
            ),
            AgentTranscriptMessage(
                role: .tool, text: "ok", toolCallID: "call-1", toolName: "ssh_exec"
            ),
            AgentTranscriptMessage(
                role: .tool, text: "[]",
                toolCallID: "provider-web-search-11328F4A", toolName: "web_search"
            ),
            AgentTranscriptMessage(role: .assistant, text: "Done."),
        ]

        let repaired = AgentRuntime.withoutOrphanedToolResults(history)

        #expect(repaired.count == 4)
        #expect(!repaired.contains { $0.toolCallID?.hasPrefix("provider-web-search") == true })
        // The answered one survives, or the model loses what its tool returned.
        #expect(repaired.contains { $0.toolCallID == "call-1" })
    }

    @Test
    func toolResultsWithoutACallIDAreKept() {
        // Google addresses a tool result by name, not by id, so an absent id is
        // not evidence of an orphan.
        let history = [
            AgentTranscriptMessage(role: .tool, text: "ok", toolName: "list_hosts")
        ]
        #expect(AgentRuntime.withoutOrphanedToolResults(history).count == 1)
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
