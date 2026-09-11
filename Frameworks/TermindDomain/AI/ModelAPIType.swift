import AgentKit
import Foundation

/// What the API Type picker offers.
///
/// The four cases past `.automatic` mirror `ModelAPIFormat` one for one.
/// `.automatic` is not a fifth request shape — it is a *choice*, "read the
/// shape off the URL I pasted" — which is why it lives here rather than in
/// AgentKit: nothing that builds a request can act on it, and by the time one
/// does the choice has already been resolved to a format.
public nonisolated enum ModelAPIType: String, Codable, Sendable, CaseIterable, Identifiable {
    /// First because it is the answer for almost everyone: people paste the URL
    /// their gateway's documentation gave them, and that URL already says which
    /// endpoint it is.
    case automatic
    case chatCompletions
    case responses
    case messages
    case generateContent

    public nonisolated var id: String { rawValue }

    /// `nil` for `.automatic`, which is the whole difference between the two
    /// types — see `ProviderEndpoint.format` for how it is filled in.
    public var format: ModelAPIFormat? {
        switch self {
        case .automatic: nil
        case .chatCompletions: .chatCompletions
        case .responses: .responses
        case .messages: .messages
        case .generateContent: .generateContent
        }
    }

    public init(_ format: ModelAPIFormat) {
        switch format {
        case .chatCompletions: self = .chatCompletions
        case .responses: self = .responses
        case .messages: self = .messages
        case .generateContent: self = .generateContent
        }
    }

    public var displayName: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        default: format?.displayName ?? ""
        }
    }

    public var symbol: String {
        switch self {
        case .automatic: "wand.and.stars"
        default: format?.symbol ?? ""
        }
    }
}

nonisolated extension ModelAPIFormat {
    /// Left in English on purpose. These are the endpoint names a gateway's own
    /// documentation prints, and translating them would mean the label in
    /// Settings no longer matches the page the URL was copied from.
    public var displayName: String {
        switch self {
        case .chatCompletions: "Chat Completions"
        case .responses: "Responses"
        case .messages: "Messages"
        case .generateContent: "generateContent"
        }
    }

    public var symbol: String {
        switch self {
        case .chatCompletions: "bubble.left.and.bubble.right"
        case .responses: "arrow.left.arrow.right"
        case .messages: "message"
        case .generateContent: "diamond"
        }
    }

    /// Appended to a URL that does not already name an endpoint.
    public var path: String {
        switch self {
        case .chatCompletions: "/chat/completions"
        case .responses: "/responses"
        case .messages: "/messages"
        // The only one that needs the token: this shape addresses the model in
        // the path rather than in the body.
        case .generateContent: "/models/\(ModelProvider.modelToken):generateContent"
        }
    }

    /// A typed URL taken apart the way composing an address needs it.
    public nonisolated struct URLParts: Hashable, Sendable {
        /// The path as typed, minus any trailing slash and without the query.
        /// What a request keeps using when the URL already named its endpoint.
        public var path: String = ""
        /// `path` with the recognised endpoint removed, or `path` itself when
        /// none was recognised. Where `/models` gets appended.
        public var base: String = ""
        /// `?…`, kept aside so an appended path does not land behind it.
        public var query: String = ""
        /// The endpoint the URL names, if it names one.
        public var endpoint: ModelAPIFormat?
        public init(path: String = "", base: String = "", query: String = "", endpoint: ModelAPIFormat? = nil) {
            self.path = path
            self.base = base
            self.query = query
            self.endpoint = endpoint
        }

    }

    /// The endpoint a pasted URL names, if it names one.
    public static func detected(in url: String) -> ModelAPIFormat? {
        parts(of: url).endpoint
    }

    /// Suffix matching rather than anything cleverer, because a gateway is free
    /// to serve `/anthropic/v1/messages` or `/openai/v1/chat/completions` and
    /// only the tail is common to all of them.
    ///
    /// `generateContent` needs more than a fixed suffix: it names the model
    /// *inside* the path, so what has to come off to reach the base runs from
    /// the `/models/` segment rather than from the colon. Cutting at the colon
    /// instead would leave the model id behind and send `Fetch Models` to
    /// `…/models/gemini-x/models`. Streaming counts as the same endpoint —
    /// `:streamGenerateContent` carries the same body, and someone who pasted
    /// it has still said which shape they meant.
    public static func parts(of url: String) -> URLParts {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryStart = trimmed.firstIndex(of: "?")
        var path = queryStart.map { String(trimmed[trimmed.startIndex..<$0]) } ?? trimmed
        let query = queryStart.map { String(trimmed[$0...]) } ?? ""
        while path.hasSuffix("/") { path.removeLast() }

        let endsWithGenerateContent =
            path.range(of: "generateContent", options: [.anchored, .backwards, .caseInsensitive])
            != nil
        if endsWithGenerateContent,
            let models = path.range(of: "/models/", options: [.backwards, .caseInsensitive])
        {
            return URLParts(
                path: path, base: String(path[path.startIndex..<models.lowerBound]),
                query: query, endpoint: .generateContent
            )
        }

        for (suffix, format) in fixedSuffixes {
            guard
                let match = path.range(
                    of: suffix, options: [.anchored, .backwards, .caseInsensitive]
                )
            else { continue }
            return URLParts(
                path: path, base: String(path[path.startIndex..<match.lowerBound]),
                query: query, endpoint: format
            )
        }

        return URLParts(path: path, base: path, query: query, endpoint: nil)
    }

    /// Longest first, so `/chat/completions` is never read as something shorter
    /// that happens to end it.
    private static let fixedSuffixes: [(String, ModelAPIFormat)] = [
        ("/chat/completions", .chatCompletions),
        ("/responses", .responses),
        ("/messages", .messages),
    ]
}

/// The two things the provider editor owns: the one URL that was typed, and
/// which API type was picked for it.
///
/// `ModelProvider.url` and `.apiFormat` are *derived* from this pair and are
/// never edited directly — see `AIConfigurationModel.setEndpoint(_:for:)`,
/// which is the only writer. Kept beside the provider rather than on it
/// because `ModelProvider` belongs to AgentKit, and because neither field is
/// recoverable from the composed result: a URL ending in `/messages` looks the
/// same whether the user typed that suffix or Termind appended it, and
/// `.automatic` looks the same as picking the format it resolved to.
public nonisolated struct ProviderEndpoint: Codable, Hashable, Sendable {
    public var apiType: ModelAPIType = .automatic
    public var url: String = ""

    public init(apiType: ModelAPIType = .automatic, url: String = "") {
        self.apiType = apiType
        self.url = url
    }

    private var parts: ModelAPIFormat.URLParts {
        ModelAPIFormat.parts(of: url)
    }

    /// The endpoint named by the URL, whether or not it is being used.
    public var detectedFormat: ModelAPIFormat? { parts.endpoint }

    /// Which shape requests are actually encoded as.
    ///
    /// An explicit pick wins over the URL, so choosing `Messages` for a URL
    /// ending in `/chat/completions` sends Anthropic bodies to that path rather
    /// than quietly overruling the person who chose it. Chat Completions is the
    /// fallback because it is what an endpoint that does not name itself is
    /// almost always serving.
    public var format: ModelAPIFormat {
        apiType.format ?? detectedFormat ?? .chatCompletions
    }

    /// The address handed to AgentKit: the URL as typed when it already names
    /// an endpoint, and otherwise the URL with this format's path appended.
    ///
    /// As typed rather than recomposed, so an explicit API type that disagrees
    /// with the URL changes the body and not the destination — the person who
    /// pasted the address gets to keep it.
    public var requestURL: String {
        let parts = parts
        guard !parts.path.isEmpty else { return "" }
        return (parts.endpoint == nil ? parts.base + format.path : parts.path) + parts.query
    }

    /// The address a model listing hangs off: the typed URL with any endpoint
    /// removed. AgentKit appends `/models` to it — see
    /// `ModelProvider.resolvedModelsURL`.
    public var baseURL: String {
        let parts = parts
        guard !parts.path.isEmpty else { return "" }
        return parts.base + parts.query
    }

    public var isConfigured: Bool { !parts.path.isEmpty }
}
