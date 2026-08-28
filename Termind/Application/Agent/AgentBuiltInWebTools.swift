import Foundation

nonisolated extension AgentBuiltInTools {
    private static var fetchContentLimit: Int { 256 * 1_024 }
    private static var searchMarkdownLimit: Int { 32 * 1_024 }

    static func fetch(_ web: ScrubberWebClient) -> AnyAgentTool {
        let tool = descriptor(
            "fetch",
            "Read an HTTP(S) webpage, including private-network pages. Returns Markdown by "
                + "default, or the original HTML when format is original.",
            properties: [
                "url": string(max: 8_192),
                "format": enumeration(["markdown", "original"]),
            ],
            required: ["url"], target: .network, safety: .locallyReadOnly,
            concurrency: .parallel,
            presentation: .init(
                symbol: "globe", activity: .semanticArgument(key: "url", fallback: .url),
                output: .field("content"),
                detailPresenterID: "builtin.fetch",
                actionKind: .fetch
            )
        )
        return AnyAgentTool(
            descriptor: tool,
            preflight: { invocation in
                _ = try ScrubberWebClient.validatedURL(Arguments(invocation).string("url"))
                return AgentToolPreflight(invocation: invocation, safety: .locallyReadOnly)
            },
            execute: { invocation, _ in
                let arguments = try Arguments(invocation)
                let document = try await web.document(
                    for: arguments.string("url")
                )
                let format = arguments.optionalString("format") ?? "markdown"
                let selected = format == "original" ? document.original : document.markdown
                let content = bounded(selected, maximumBytes: fetchContentLimit)
                return result(invocation, .object([
                    "title": .string(document.title),
                    "url": .string(document.url.absoluteString),
                    "format": .string(format),
                    "content": .string(content.text),
                    "truncated": .bool(content.truncated),
                ]), truncated: content.truncated)
            }
        )
    }

    static func webSearch(_ web: ScrubberWebClient) -> AnyAgentTool {
        let tool = descriptor(
            "web_search",
            "Search Google, Bing, DuckDuckGo, and Yahoo, then return readable Markdown from the "
                + "result pages.",
            properties: ["query": string(max: 1_024), "count": integer(min: 1, max: 5)],
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
                return AgentToolPreflight(invocation: invocation, safety: .locallyReadOnly)
            },
            execute: { invocation, _ in
                let arguments = try Arguments(invocation)
                let rows = try await web.search(
                    arguments.string("query"), count: arguments.optionalInt("count") ?? 5
                )
                return result(invocation, .array(rows.map { row in
                    let markdown = bounded(row.markdown, maximumBytes: searchMarkdownLimit)
                    return .object([
                        "engine": row.engine.map(AgentJSONValue.string) ?? .null,
                        "title": .string(row.title), "url": .string(row.url.absoluteString),
                        "markdown": .string(markdown.text),
                        "truncated": .bool(markdown.truncated),
                    ])
                }), truncated: rows.contains { $0.markdown.utf8.count > searchMarkdownLimit })
            }
        )
    }

    private static func bounded(_ text: String, maximumBytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > maximumBytes else { return (text, false) }
        return (String(decoding: text.utf8.prefix(maximumBytes), as: UTF8.self), true)
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
        if let title = F.nonempty(object["title"]?.stringValue) {
            items.append(F.field("Title", title, locale: input.locale))
        }
        if let url = F.nonempty(object["url"]?.stringValue) {
            items.append(.field(.init(
                label: F.localized("URL", locale: input.locale), value: url,
                isMonospaced: true, url: url
            )))
        }
        let format = object["format"]?.stringValue ?? "markdown"
        let content = object["content"]?.stringValue ?? ""
        items.append(content.isEmpty
                ? .message(F.localized("No readable page content", locale: input.locale), .secondary)
                : .text(.init(
                    title: F.localized(format == "original" ? "Original HTML" : "Markdown", locale: input.locale),
                    text: content, style: .plain
                )))
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
            let engine = F.nonempty(object["engine"]?.stringValue)
            let truncated = object["truncated"]?.boolValue == true
                ? F.localized("Truncated", locale: input.locale) : nil
            return .init(
                title: title, subtitle: url,
                detail: [engine, truncated].compactMap { $0 }.joined(separator: " · "),
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
