import Foundation

nonisolated extension AgentBuiltInTools {
    static func fetch(_ fetcher: RestrictedHTTPFetcher) -> AnyAgentTool {
        let header = object(
            properties: [
                "name": string(max: RestrictedHTTPHeaderValidator.maximumNameBytes),
                "value": string(max: RestrictedHTTPHeaderValidator.maximumValueBytes),
            ],
            required: ["name", "value"]
        )
        let tool = descriptor(
            "fetch",
            "Fetch bounded HTTP(S), including approved private-network targets. Custom headers "
                + "follow every redirect, including cross-origin redirects, like curl -H -L.",
            properties: [
                "url": string(max: 8_192), "method": enumeration(["GET", "HEAD"]),
                "headers": array(items: header, max: RestrictedHTTPHeaderValidator.maximumCount),
            ],
            required: ["url"], target: .network, safety: .locallyReadOnly,
            // GET and HEAD only, over separate connections, against a server
            // that already expects concurrency. This is where parallel tool
            // calls pay for themselves.
            concurrency: .parallel,
            presentation: .init(
                symbol: "globe", activity: .argument(key: "url", fallback: "a URL"),
                output: .field("body"),
                action: .init(infinitive: "fetch", progressive: "Fetching", past: "Fetched")
            )
        )
        return AnyAgentTool(
            descriptor: tool,
            preflight: { invocation in
                let arguments = try Arguments(invocation)
                let url = try arguments.string("url")
                _ = try RestrictedHTTPHeaderValidator.validate(arguments.requestHeaders())
                guard try await fetcher.classification(for: url) == .restricted else {
                    return AgentToolPreflight(invocation: invocation, safety: .locallyReadOnly)
                }
                guard let parsedURL = URL(string: url) else { throw RestrictedFetchError.invalidURL }
                let origin = try PublicAddressValidator.origin(of: parsedURL)
                return AgentToolPreflight(
                    invocation: invocation,
                    safety: .requiresAuthorization,
                    reasons: ["The fetch target is on a private or otherwise non-public network: \(url)"],
                    executionMetadata: ["authorized_fetch_origins": .array([.string(origin)])]
                )
            },
            execute: { invocation, context in
                let arguments = try Arguments(invocation)
                let headers = try arguments.requestHeaders()
                let authorizedOrigins = Set(
                    context.preflightMetadata["authorized_fetch_origins"]?.arrayValue?
                        .compactMap(\.stringValue) ?? []
                )
                let response = try await fetcher.fetch(
                    try arguments.string("url"),
                    method: arguments.optionalString("method") ?? "GET",
                    headers: headers,
                    authorizedRestrictedOrigins: authorizedOrigins,
                    authorizeRestrictedOrigin: { url, _ in
                        var escalation = tool
                        escalation.safety = .requiresAuthorization
                        var reasons = [
                            "The fetch redirect enters a private or otherwise non-public network: "
                                + url.absoluteString
                        ]
                        if !headers.isEmpty {
                            reasons.append(
                                "Custom headers follow this redirect, including across origins, "
                                    + "matching curl -H -L behavior."
                            )
                        }
                        let request = AgentApprovalRequest(
                            invocation: invocation,
                            descriptor: escalation,
                            userIntent: context.userIntent,
                            localReasons: reasons
                        )
                        switch await context.authorize(request) {
                        case .allow: return
                        case .deny(let reason): throw RestrictedFetchError.authorizationDenied(reason)
                        }
                    }
                )
                return result(invocation, .object([
                    "url": .string(response.url.absoluteString),
                    "status": .number(Double(response.status)),
                    "headers": .object(response.headers.mapValues(AgentJSONValue.string)),
                    "body": .string(response.body), "truncated": .bool(response.truncated),
                ]), truncated: response.truncated)
            }
        )
    }

    /// Finding a URL, as the counterpart to `fetch` reading one.
    ///
    /// Snippets only, deliberately. Every backend here can also return page
    /// text, and taking it would make this a second way to read the web —
    /// one whose destination is chosen by the search engine rather than
    /// classified by us. Leaving it out keeps `fetch` the single door, with its
    /// address classification, redirect budget and private-network escalation
    /// all still on the path.
    ///
    /// `.locallyReadOnly` for a public backend, matching `fetch`: a query is an
    /// outbound request, not a change to anything. It escalates for the same
    /// destinations `fetch` escalates for, which is what stops a search backend
    /// configured at a LAN address from being reached without a word.
    static func webSearch(_ search: WebSearchClient) -> AnyAgentTool {
        let tool = descriptor(
            "web_search",
            "Search the public web. Returns titles, URLs and snippets only; use fetch to read a "
                + "result page in full.",
            properties: ["query": string(max: 1_024), "count": integer(min: 1, max: 10)],
            required: ["query"], target: .network, safety: .locallyReadOnly,
            concurrency: .parallel,
            presentation: .init(
                symbol: "magnifyingglass",
                activity: .argument(key: "query", fallback: "the web"), output: .json,
                action: .init(infinitive: "search", progressive: "Searching", past: "Searched")
            )
        )
        return AnyAgentTool(
            descriptor: tool,
            preflight: { invocation in
                _ = try Arguments(invocation).string("query")
                guard try await search.classification() == .restricted else {
                    return AgentToolPreflight(invocation: invocation, safety: .locallyReadOnly)
                }
                return AgentToolPreflight(
                    invocation: invocation,
                    safety: .requiresAuthorization,
                    reasons: [
                        "The configured search backend is on a private or otherwise non-public "
                            + "network: \(search.resolvedURL)"
                    ]
                )
            },
            execute: { invocation, _ in
                let arguments = try Arguments(invocation)
                let rows = try await search.search(
                    arguments.string("query"), count: arguments.optionalInt("count") ?? 5
                )
                return result(invocation, .array(rows.map { row in
                    .object([
                        "title": .string(row.title), "url": .string(row.url),
                        "snippet": .string(row.snippet),
                        "published_at": row.publishedAt.map { .string($0.ISO8601Format()) } ?? .null,
                    ])
                }))
            }
        )
    }
}

