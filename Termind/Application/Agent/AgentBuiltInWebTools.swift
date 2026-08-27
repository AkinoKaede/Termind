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
                symbol: "globe", activity: .semanticArgument(key: "url", fallback: .url),
                output: .field("body"),
                detailPresenterID: "builtin.fetch",
                actionKind: .fetch
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
                activity: .semanticArgument(key: "query", fallback: .web), output: .json,
                detailPresenterID: "builtin.web_search",
                actionKind: .search
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

// MARK: - Tool-owned transcript details

nonisolated extension AgentBuiltInTools {
    static let fetchDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.fetch", present: presentFetchDetail
    )
    static let webSearchDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.web_search", present: presentWebSearchDetail
    )

    private static func presentFetchDetail(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
        var items: [AgentToolDetail.Item] = []
        if let url = F.nonempty(object["url"]?.stringValue) {
            items.append(.field(.init(
                label: F.localized("URL", locale: input.locale), value: url,
                isMonospaced: true, url: url
            )))
        }
        if let status = object["status"]?.integerValue {
            items.append(F.field("Status", String(status), locale: input.locale))
        }
        if let headers = object["headers"]?.objectValue, !headers.isEmpty {
            let rows = headers.keys.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }.map { name in
                AgentToolDetail.ListRow(title: name, subtitle: headers[name]?.stringValue ?? "")
            }
            items.append(.list(.init(
                title: F.localized("Response headers", locale: input.locale), rows: rows
            )))
        }
        if input.arguments["method"]?.stringValue ?? "GET" != "HEAD" {
            let body = object["body"]?.stringValue ?? ""
            items.append(body.isEmpty
                ? .message(F.localized("Empty response body", locale: input.locale), .secondary)
                : .text(.init(
                    title: F.localized("Response body", locale: input.locale),
                    text: body, style: .plain
                )))
        }
        return items
    }

    private static func presentWebSearchDetail(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let values = input.result.arrayValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
        let rows = values.compactMap { entry -> AgentToolDetail.ListRow? in
            guard let object = entry.objectValue else { return nil }
            let url = F.nonempty(object["url"]?.stringValue)
            let title = F.nonempty(object["title"]?.stringValue) ?? url
                ?? F.localized("Untitled result", locale: input.locale)
            let snippet = F.nonempty(object["snippet"]?.stringValue)
            let published = object["published_at"]?.stringValue.map(F.displayDate)
            return .init(
                title: title, subtitle: url,
                detail: [snippet, published].compactMap { $0 }.joined(separator: "\n"),
                symbol: "link", url: url
            )
        }
        return [
            .message(String(localized: "\(rows.count) results", locale: input.locale), .secondary),
            .list(.init(
                title: nil, rows: rows,
                emptyMessage: F.localized("No results", locale: input.locale)
            )),
        ]
    }
}
