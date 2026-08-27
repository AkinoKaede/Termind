import Foundation

/// Which search endpoint's wire protocol Termind speaks.
///
/// Four, and for the same reason `ModelProviderKind` is three: these are
/// *shapes*, not vendors. Unlike chat completions there is no de-facto standard
/// one of them can stand in for — Bing answers a GET with a web page, Brave
/// with `web.results`, Tavily with `results[].content`, Exa with
/// `results[].text` — so each shape genuinely costs a case. A self-hosted or
/// compatible endpoint is reached by overriding `baseURL` on whichever shape it
/// imitates, which is what keeps this list from growing a case per vendor.
nonisolated enum SearchBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Reads `bing.com/search` the way a browser would, with no account and no
    /// key. Ported from Kelivo's `BingSearchService`, down to the `b_algo`
    /// selectors.
    ///
    /// The default, and reachability is why: it answers from networks where
    /// `.duckDuckGo` is blocked, and a default that times out for a large part
    /// of the world is not a default. Every other candidate needs a key, so
    /// this is the only one that can be switched on out of the box everywhere.
    ///
    /// Its relevance is the weak point, and it is worth knowing before trusting
    /// it. Bing degrades an anonymous request to roughly first-token matching:
    /// verified live, "nginx 502 bad gateway upstream timeout" returns
    /// nginx.org's home page and download page, and "CVE-2024-3094 xz backdoor"
    /// returns cve.org's landing page — with the query echoed correctly in the
    /// page title and the terms appearing nowhere in the results. A full set of
    /// browser headers, a cookie jar, `form=`, `setlang`/`cc` and `mkt` in
    /// every combination moved none of it; only `mkt` mattered, and only to
    /// stop the results being unrelated *and* in the wrong language.
    case bing
    /// Reads DuckDuckGo's HTML endpoint the way a browser would, also with no
    /// account and no key.
    ///
    /// Markedly better results than `.bing` where it is reachable: against the
    /// live endpoints, "CVE-2024-3094 xz backdoor" returns the NVD record, the
    /// CVE record and the Wikipedia article, where Bing returns none of them.
    /// Worth switching to wherever the endpoint resolves.
    case duckDuckGo
    case brave
    case tavily
    case exa

    /// One place to change what an unset or unrecognised preference means.
    static let `default` = SearchBackend.bing

    nonisolated var id: String { rawValue }

    /// "(Local)" marks the two that are not APIs: the request leaves this Mac
    /// looking like a browser and the answer is a web page Termind reads
    /// itself. Borrowed from Kelivo, and worth carrying because the difference
    /// is one a user is entitled to know — no key, no contract, and it stops
    /// working the day the markup moves.
    var displayName: String {
        switch self {
        case .bing: "Bing (Local)"
        case .duckDuckGo: "DuckDuckGo (Local)"
        case .brave: "Brave Search"
        case .tavily: "Tavily"
        case .exa: "Exa"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .bing, .duckDuckGo: false
        case .brave, .tavily, .exa: true
        }
    }

    /// Whether the answer is a web page rather than an API payload. The two
    /// that are share a byte budget, a browser user agent, and the caveat that
    /// they break when markup moves.
    var readsMarkup: Bool {
        switch self {
        case .bing, .duckDuckGo: true
        case .brave, .tavily, .exa: false
        }
    }

    /// Carries whatever version segment the vendor's own documentation prints,
    /// and none where it prints none — the same rule
    /// `ModelProviderKind.defaultBaseURL` follows, for the same reason: the
    /// user pastes what they were given.
    var defaultBaseURL: String {
        switch self {
        case .duckDuckGo: "https://html.duckduckgo.com"
        case .bing: "https://www.bing.com"
        case .brave: "https://api.search.brave.com/res/v1"
        case .tavily: "https://api.tavily.com"
        case .exa: "https://api.exa.ai"
        }
    }

    var path: String {
        switch self {
        case .duckDuckGo: "/html/"
        case .bing: "/search"
        case .brave: "/web/search"
        case .tavily, .exa: "/search"
        }
    }

    /// Redirects are refused outright for the keyed backends: their request
    /// carries an API key in a header, and following a redirect would hand that
    /// key to whatever host the response named. The keyless two carry no
    /// credential and do bounce through region and consent hops, so they get a
    /// small budget.
    var maximumRedirects: Int {
        readsMarkup ? 3 : 0
    }

    /// A search-results page is two orders of magnitude larger than a JSON
    /// answer, and truncating one mid-markup loses results rather than trimming
    /// them.
    var responseByteLimit: Int {
        readsMarkup ? 4 * 1_024 * 1_024 : 512 * 1_024
    }

    /// Where to get a key, shown under the field. Every keyed backend here is
    /// bring-your-own — Termind holds no search credential of its own, exactly
    /// as it holds no model credential of its own.
    var detail: String {
        switch self {
        case .bing:
            String(localized: "No account or key. Reachable almost anywhere.")
        case .duckDuckGo:
            String(localized: "No account or key.")
        case .brave:
            String(localized: "Subscription token from the Brave Search API dashboard.")
        case .tavily:
            String(localized: "API key from the Tavily dashboard.")
        case .exa:
            String(localized: "API key from the Exa dashboard.")
        }
    }
}

nonisolated struct WebSearchResult: Hashable, Sendable {
    var title: String
    var url: String
    var snippet: String
    var publishedAt: Date?
}

/// One search backend, configured once in Settings.
///
/// Shares `RestrictedHTTPFetcher`'s address classifier: the resolved endpoint is
/// re-resolved immediately before the request, so a mistyped self-hosted base
/// URL cannot quietly aim at something on the user's own network. The
/// classification is repeated here rather than trusted from preflight because
/// DNS can change between the two, and it is what makes an unspecified or
/// multicast address a throw rather than a connection.
///
/// Whether a *restricted* result is allowed is not decided here — `web_search`
/// escalates to approval in preflight for exactly the destinations `fetch`
/// does, so a search backend configured at a LAN address is disclosed rather
/// than silently reached.
nonisolated struct WebSearchClient: Sendable {
    typealias Classifier = @Sendable (URL) async throws -> RestrictedNetworkScope

    var backend: SearchBackend
    /// Blank means `backend.defaultBaseURL`.
    var baseURL: String
    /// Empty for backends that need none. `requiresAPIKey` decides whether that
    /// is a configuration error or the ordinary case.
    var apiKey: String
    var timeout: TimeInterval
    /// Only Bing reads it. Sent so a user in a Chinese or Japanese locale gets
    /// their own results rather than an American default, which for a search
    /// engine is a correctness matter and not a preference.
    var acceptLanguage: String
    /// Bing's market, `language-REGION`.
    ///
    /// Not optional, and not a nicety. Verified against the live endpoint: with
    /// no `mkt`, Bing answers an anonymous request with a page that is
    /// well-formed, correctly titled with the query, and full of `b_algo`
    /// results for something else entirely — a search for "swift 6 concurrency"
    /// came back as Chinese-language threads about ChatGPT. Sending a cookie
    /// jar made it worse rather than better.
    ///
    /// That is the worst failure this feature could have. The request
    /// succeeds, the parse succeeds, and the model is handed confident
    /// nonsense with no signal that anything went wrong. `mkt` is the whole
    /// difference between that and results that match the query.
    var market: String
    var classify: Classifier

    init(
        backend: SearchBackend,
        baseURL: String = "",
        apiKey: String = "",
        timeout: TimeInterval = 20,
        acceptLanguage: String = WebSearchClient.preferredLanguages,
        market: String = WebSearchClient.preferredMarket,
        classify: @escaping Classifier = PublicAddressValidator.classify
    ) {
        self.backend = backend
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        self.acceptLanguage = acceptLanguage
        self.market = market
        self.classify = classify
    }

    /// A browser user agent, because these two requests really are that: an
    /// ordinary page load. Both engines serve a stripped page to anything that
    /// does not look like a browser, and the stripped page has none of the
    /// result markup the parsers below read.
    ///
    /// Safari on macOS specifically. The request is coming from a Mac over
    /// Apple's own networking stack, so claiming Chrome on Windows would make
    /// the user agent the one part of it that disagrees with every other part.
    static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    static var preferredLanguages: String {
        let codes = Locale.preferredLanguages.prefix(3)
        guard !codes.isEmpty else { return "en-US,en;q=0.9" }
        return codes.enumerated()
            .map { index, code in index == 0 ? code : "\(code);q=\(1.0 - 0.1 * Double(index))" }
            .joined(separator: ",")
    }

    /// Falls back to `en-US` a component at a time rather than all at once, so
    /// a Mac with a language but no region still searches in its own language.
    static var preferredMarket: String {
        let locale = Locale.current
        let language = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier ?? "US"
        return "\(language)-\(region)"
    }

    var resolvedBaseURL: String {
        let typed = baseURL.trimmingCharacters(in: .whitespaces)
        let value = typed.isEmpty ? backend.defaultBaseURL : typed
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    var resolvedURL: String { resolvedBaseURL + backend.path }

    /// True when this backend is usable as configured. A keyless backend is
    /// always ready, which is what lets Web Search work the moment it is
    /// switched on.
    var isConfigured: Bool {
        !backend.requiresAPIKey || !apiKey.isEmpty
    }

    /// Where the query would actually go, for the tool's preflight check and
    /// for the caption under the Settings fields.
    func classification() async throws -> RestrictedNetworkScope {
        guard let url = URL(string: resolvedURL) else { throw WebSearchError.invalidEndpoint }
        return try await classify(url)
    }

    func search(_ query: String, count: Int) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebSearchError.emptyQuery }
        guard isConfigured else { throw WebSearchError.missingKey }
        let limit = min(max(count, 1), 10)

        let request = try buildRequest(query: trimmed, count: limit)
        guard let url = request.url else { throw WebSearchError.invalidEndpoint }
        _ = try await classify(url)

        let delegate = SearchRedirectDelegate(
            maximumRedirects: backend.maximumRedirects, classify: classify
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebSearchError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            if data.count >= backend.responseByteLimit { break }
            data.append(byte)
        }
        if (300..<400).contains(http.statusCode) { throw WebSearchError.blockedRedirect }
        guard (200..<300).contains(http.statusCode) else {
            throw WebSearchError.http(
                http.statusCode, String(decoding: data.prefix(2_048), as: UTF8.self)
            )
        }
        return try Self.decode(data, backend: backend, limit: limit)
    }

    /// DuckDuckGo's region, which is `mkt` with its halves swapped and
    /// lowercased: `en-US` here is `us-en` there.
    var duckDuckGoRegion: String {
        let parts = market.split(separator: "-")
        guard parts.count == 2 else { return "wt-wt" }
        return "\(parts[1].lowercased())-\(parts[0].lowercased())"
    }

    func buildRequest(query: String, count: Int) throws -> URLRequest {
        switch backend {
        case .duckDuckGo:
            guard let url = URL(string: resolvedURL) else { throw WebSearchError.invalidEndpoint }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(
                "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"
            )
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
            request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
            var form = URLComponents()
            form.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "kl", value: duckDuckGoRegion),
            ]
            request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
            return request

        case .bing:
            guard var components = URLComponents(string: resolvedURL) else {
                throw WebSearchError.invalidEndpoint
            }
            components.queryItems =
                (components.queryItems ?? [])
                + [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "mkt", value: market),
                ]
            guard let url = components.url else { throw WebSearchError.invalidEndpoint }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
            request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
            return request

        case .brave:
            guard var components = URLComponents(string: resolvedURL) else {
                throw WebSearchError.invalidEndpoint
            }
            components.queryItems =
                (components.queryItems ?? [])
                + [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "count", value: String(count)),
                ]
            guard let url = components.url else { throw WebSearchError.invalidEndpoint }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
            return request

        case .tavily:
            return try postRequest(
                headers: ["Authorization": "Bearer \(apiKey)"],
                body: ["query": query, "max_results": count]
            )

        case .exa:
            // `contents.text` with a character cap is what keeps this a snippet
            // rather than a page fetch. Reading a page in full stays the job of
            // `fetch`, which is the one path with a redirect budget and address
            // classification on the *target* rather than on the search API.
            return try postRequest(
                headers: ["x-api-key": apiKey],
                body: [
                    "query": query, "numResults": count,
                    "contents": ["text": ["maxCharacters": 600]],
                ]
            )
        }
    }

    private func postRequest(
        headers: [String: String], body: [String: Any]
    ) throws -> URLRequest {
        guard let url = URL(string: resolvedURL) else { throw WebSearchError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Decoding

    static func decode(
        _ data: Data, backend: SearchBackend, limit: Int
    ) throws -> [WebSearchResult] {
        guard backend.readsMarkup else {
            return try decodeJSON(data, backend: backend, limit: limit)
        }
        let html = String(decoding: data, as: UTF8.self)
        return backend == .bing
            ? bingResults(html, limit: limit)
            : duckDuckGoResults(html, limit: limit)
    }

    /// Lenient on purpose. Every field but the URL is optional on the wire, and
    /// a row missing its URL is dropped rather than thrown on: one malformed
    /// result should not lose the other nine.
    private static func decodeJSON(
        _ data: Data, backend: SearchBackend, limit: Int
    ) throws -> [WebSearchResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebSearchError.invalidResponse
        }
        let rows: [[String: Any]]
        switch backend {
        case .brave:
            let web = root["web"] as? [String: Any]
            rows = web?["results"] as? [[String: Any]] ?? []
        case .tavily, .exa:
            rows = root["results"] as? [[String: Any]] ?? []
        case .bing, .duckDuckGo:
            rows = []
        }
        return rows.prefix(limit).compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            let snippet: String? =
                switch backend {
                case .brave: row["description"] as? String
                case .tavily: row["content"] as? String
                case .exa: row["text"] as? String
                case .bing, .duckDuckGo: nil
                }
            let published: String? =
                switch backend {
                case .brave: (row["page_age"] ?? row["age"]) as? String
                case .tavily: row["published_date"] as? String
                case .exa: row["publishedDate"] as? String
                case .bing, .duckDuckGo: nil
                }
            return WebSearchResult(
                title: plainText(row["title"] as? String ?? ""),
                url: url,
                snippet: plainText(snippet ?? ""),
                publishedAt: published.flatMap(date)
            )
        }
    }

    // MARK: - DuckDuckGo result page

    /// Reads `result__a` for the link and `result__snippet` for the summary,
    /// skipping any block whose class marks it an ad.
    ///
    /// Scanned with regular expressions rather than parsed, because this app
    /// ships no HTML parser and adding one for three selectors is not a trade
    /// worth making. That is a real limitation: this returns an empty list when
    /// the markup moves, which reads to the model as "no results" rather than
    /// as a failure, and is why the keyed backends are worth configuring.
    static func duckDuckGoResults(_ html: String, limit: Int) -> [WebSearchResult] {
        var results: [WebSearchResult] = []
        for block in markupBlocks(html, opener: duckDuckGoBlockPattern, classGroup: 1) {
            guard results.count < limit else { break }
            // `result--ad` and `result--sponsored` wear the same result markup.
            guard !block.classes.contains("result--ad"),
                !block.classes.contains("result--sponsored")
            else { continue }
            guard let link = firstMatch(duckDuckGoLinkPattern, in: block.body), link.count >= 3
            else { continue }
            let url = unwrapDuckDuckGoRedirect(plainText(link[1]))
            guard url.hasPrefix("http") else { continue }
            let snippet = firstMatch(duckDuckGoSnippetPattern, in: block.body)?.dropFirst().first
            results.append(WebSearchResult(
                title: plainText(link[2]),
                url: url,
                snippet: plainText(snippet ?? ""),
                publishedAt: nil
            ))
        }
        return results
    }

    /// DuckDuckGo sometimes serves links direct and sometimes through
    /// `//duckduckgo.com/l/?uddg=<percent-encoded>`. Both shapes appear on the
    /// same endpoint, so neither can be assumed.
    static func unwrapDuckDuckGoRedirect(_ raw: String) -> String {
        guard raw.contains("/l/"), raw.contains("uddg=") else { return raw }
        let absolute = raw.hasPrefix("//") ? "https:" + raw : raw
        guard let components = URLComponents(string: absolute),
            let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
            target.hasPrefix("http")
        else { return raw }
        return target
    }

    private static let duckDuckGoBlockPattern = try? NSRegularExpression(
        pattern: #"<div(?=[\s>])[^>]*\bclass="([^"]*\bresult\b[^"]*)"[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let duckDuckGoLinkPattern = try? NSRegularExpression(
        pattern: #"<a[^>]*\bclass="[^"]*\bresult__a\b[^"]*"[^>]*\bhref="([^"]+)"[^>]*>(.*?)</a>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let duckDuckGoSnippetPattern = try? NSRegularExpression(
        pattern: #"\bclass="[^"]*\bresult__snippet\b[^"]*"[^>]*>(.*?)</a>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    // MARK: - Bing result page

    /// Reads the same three selectors Kelivo does — `li.b_algo`, `h2 > a`, and
    /// `.b_algoSlug` / `.b_caption p`.
    ///
    /// Scanned with regular expressions rather than parsed, because this app
    /// ships no HTML parser and adding one for three selectors is not a trade
    /// worth making. That is a real limitation and the reason a keyed backend
    /// is worth configuring: this returns an empty list when the markup moves,
    /// which reads to the model as "no results" rather than as a failure.
    static func bingResults(_ html: String, limit: Int) -> [WebSearchResult] {
        var results: [WebSearchResult] = []
        for block in markupBlocks(html, opener: bingBlockPattern, classGroup: 1) {
            guard results.count < limit else { break }
            guard let link = firstMatch(bingLinkPattern, in: block.body), link.count >= 3 else {
                continue
            }
            let url = unwrapBingRedirect(plainText(link[1]))
            guard url.hasPrefix("http") else { continue }
            let snippet =
                firstMatch(bingSlugPattern, in: block.body)?.dropFirst().first
                ?? firstMatch(bingParagraphPattern, in: block.body)?.dropFirst().first
            results.append(WebSearchResult(
                title: plainText(link[2]),
                url: url,
                snippet: plainText(snippet ?? ""),
                publishedAt: nil
            ))
        }
        return results
    }

    // MARK: - Shared markup scanning

    nonisolated struct MarkupBlock: Sendable {
        var classes: String
        var body: String
    }

    /// Each organic result runs from its own opening tag to the next one.
    ///
    /// Slicing on the next opener rather than on a matching close tag is what
    /// makes this survive the nesting both engines use inside a result, which a
    /// regular expression cannot balance. The trailing slice runs to the end of
    /// the document and so carries the page footer with it — harmless, because
    /// every selector below is anchored to result markup that appears once.
    private static func markupBlocks(
        _ html: String, opener: NSRegularExpression?, classGroup: Int
    ) -> [MarkupBlock] {
        guard let opener else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        let matches = opener.matches(in: html, range: range).compactMap {
            match -> (classes: String, start: String.Index)? in
            guard let whole = Range(match.range, in: html) else { return nil }
            // `range(at:)` traps rather than returning nil when the pattern has
            // no such group, so the bound is checked rather than assumed: a
            // pattern edited to drop its capture would otherwise take the app
            // down on the next search.
            let classes =
                classGroup < match.numberOfRanges
                ? Range(match.range(at: classGroup), in: html).map { String(html[$0]) } ?? ""
                : ""
            return (classes, whole.upperBound)
        }
        return matches.enumerated().map { index, match in
            let end = index + 1 < matches.count ? matches[index + 1].start : html.endIndex
            return MarkupBlock(classes: match.classes, body: String(html[match.start..<end]))
        }
    }

    /// Bing wraps many result links in `bing.com/ck/a?...&u=a1<base64url>`.
    /// Handing that to the model is handing it a URL that says nothing about
    /// the source, so the real one is recovered where it is recoverable.
    static func unwrapBingRedirect(_ raw: String) -> String {
        guard raw.contains("/ck/a"),
            let components = URLComponents(string: raw),
            let encoded = components.queryItems?.first(where: { $0.name == "u" })?.value,
            encoded.hasPrefix("a1")
        else { return raw }
        var base64 = String(encoded.dropFirst(2))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
            let url = String(data: data, encoding: .utf8),
            url.hasPrefix("http")
        else { return raw }
        return url
    }

    /// `(?=[\s>])` after the tag name, or `<li` also matches `<link` — of which
    /// a Bing page has dozens in its head, and one carrying a `class` attribute
    /// is enough to open a phantom result block ahead of the real ones.
    private static let bingBlockPattern = try? NSRegularExpression(
        pattern: #"<li(?=[\s>])[^>]*\bclass="([^"]*\bb_algo\b[^"]*)"[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let bingLinkPattern = try? NSRegularExpression(
        pattern: #"<h2[^>]*>.*?<a[^>]*\bhref="([^"]+)"[^>]*>(.*?)</a>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let bingSlugPattern = try? NSRegularExpression(
        pattern: #"<p[^>]*\bclass="[^"]*\bb_algoSlug\b[^"]*"[^>]*>(.*?)</p>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let bingParagraphPattern = try? NSRegularExpression(
        pattern: #"<p[^>]*>(.*?)</p>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// Returns the whole match followed by its capture groups, so callers index
    /// them the way the pattern reads.
    private static func firstMatch(
        _ regex: NSRegularExpression?, in text: String
    ) -> [String]? {
        guard let regex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    // MARK: - Shared cleanup

    /// Brave marks query terms in descriptions with `<strong>`, and Bing's
    /// snippets are raw page markup. The model reads these as text, so the tags
    /// are noise that costs tokens and invites a snippet to be mistaken for
    /// instructions in markup.
    static func plainText(_ raw: String) -> String {
        numericEntitiesDecoded(
            raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        )
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&apos;", with: "'")
        // Last, or an escaped entity such as `&amp;lt;` decodes twice.
        .replacingOccurrences(of: "&amp;", with: "&")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodes `&#183;` and `&#x27;` generally, rather than listing the ones
    /// seen so far.
    ///
    /// Bing writes its date separator as `&#0183;&#32;` and its apostrophes as
    /// `&#39;`, so a fixed list of named entities leaves raw `&#0183;` sitting
    /// in the snippet the model reads. There is no bound on which code points a
    /// result page will use, so this handles the form rather than the instances.
    private static func numericEntitiesDecoded(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        var output = ""
        var rest = Substring(text)
        while let marker = rest.range(of: "&#") {
            output += rest[..<marker.lowerBound]
            let body = rest[marker.upperBound...]
            // A `;` arbitrarily far away is a stray `&#`, not an entity.
            // Without the cap, the text between here and the next semicolon
            // anywhere in the document would be swallowed.
            guard let end = body.prefix(8).firstIndex(of: ";") else {
                output += rest[marker.lowerBound...]
                return output
            }
            let digits = body[..<end]
            let isHex = digits.first == "x" || digits.first == "X"
            if let value = UInt32(isHex ? digits.dropFirst() : digits, radix: isHex ? 16 : 10),
                let scalar = Unicode.Scalar(value)
            {
                output.unicodeScalars.append(scalar)
            } else {
                output += rest[marker.lowerBound...end]
            }
            rest = body[body.index(after: end)...]
        }
        return output + rest
    }

    private static func date(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = fractional.date(from: raw) { return value }
        if let value = ISO8601DateFormatter().date(from: raw) { return value }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: raw)
    }
}

/// Bounds redirects and re-classifies every hop.
///
/// `RestrictedHTTPFetcher` has its own, which also carries the caller's custom
/// headers across origins and escalates private destinations to approval. None
/// of that applies here: a search request has no user-supplied headers, and a
/// backend that redirects onto a private address is a thing to refuse rather
/// than a thing to ask about.
nonisolated private final class SearchRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let maximumRedirects: Int
    private let classify: WebSearchClient.Classifier
    private var redirectCount = 0

    init(maximumRedirects: Int, classify: @escaping WebSearchClient.Classifier) {
        self.maximumRedirects = maximumRedirects
        self.classify = classify
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let allowed = lock.withLock { () -> Bool in
            redirectCount += 1
            return redirectCount <= maximumRedirects
        }
        guard allowed, let url = request.url else {
            completionHandler(nil)
            return
        }
        Task { [classify] in
            do {
                guard try await classify(url) == .publicInternet else {
                    completionHandler(nil)
                    return
                }
                completionHandler(request)
            } catch { completionHandler(nil) }
        }
    }
}

nonisolated enum WebSearchError: LocalizedError, Sendable {
    case emptyQuery, missingKey, invalidEndpoint, invalidResponse, blockedRedirect
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .emptyQuery: String(localized: "The search query is empty.")
        case .missingKey: String(localized: "Web Search has no API key configured.")
        case .invalidEndpoint: String(localized: "The Web Search endpoint URL is invalid.")
        case .invalidResponse:
            String(localized: "The Web Search endpoint returned an unsupported response format.")
        case .blockedRedirect:
            String(localized: "The Web Search endpoint redirected somewhere Termind will not follow.")
        case .http(let status, let body):
            String(localized: "The Web Search endpoint returned \(status): \(body)")
        }
    }
}
