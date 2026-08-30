import Foundation

/// Asks an endpoint what models it offers.
///
/// The first thing in Termind that leaves the machine, and it goes straight from
/// here to the user's own endpoint — no server of ours, and nothing routed
/// through a host they happen to be SSH'd into. That is the BYOK promise made
/// literal, and the reason this file is small enough to read in one sitting.
///
/// It doubles as the connection test. A `GET /models` that returns 200 with a
/// count has proven the base URL, the path, the key, and TLS all at once; a
/// dedicated test endpoint would prove less and cost more code.
nonisolated struct ModelCatalogClient: Sendable {
    /// Long enough for a cold gateway, short enough that a wrong host does not
    /// leave a spinner up for a minute.
    static let timeout: TimeInterval = 20

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            self.session = ProviderNetworking.session(timeout: Self.timeout)
        }
    }

    /// Every model the provider advertises, already inferred over.
    ///
    /// Paginates where the vendor paginates, and stops at `pageLimit` pages so
    /// a server that always says "there's more" cannot spin forever.
    func models(for provider: ModelProvider, secret: String) async throws -> [AIModel] {
        guard !provider.usesVertexEndpoint else {
            throw ModelCatalogError.unsupportedForVertex
        }
        let base = provider.resolvedModelsURL ?? ""
        guard let url = URL(string: base) else { throw ModelCatalogError.badURL(base) }

        switch provider.kind {
        case .openAI:
            return try await openAIModels(at: url, provider: provider, secret: secret)
        case .anthropic:
            return try await anthropicModels(at: url, provider: provider, secret: secret)
        case .google:
            return try await googleModels(at: url, provider: provider, secret: secret)
        }
    }

    private static let pageLimit = 20

    // MARK: - OpenAI and compatible

    /// `GET {base}/models` → `{"data": [...]}`, unpaginated.
    ///
    /// The row decoder is doing the interesting work here rather than this
    /// method: `api.openai.com` sends `{id, object, created, owned_by}` and a
    /// good gateway sends name, type, modalities, capabilities and token limits
    /// under the same envelope. See `CatalogRow`.
    private func openAIModels(
        at url: URL,
        provider: ModelProvider,
        secret: String
    ) async throws -> [AIModel] {
        var request = URLRequest(url: url)
        try await ProviderNetworking.authorize(
            &request, provider: provider, secret: secret,
            omittingEmptyCredential: true
        )
        return try Self.parseOpenAIPage(try await get(request), provider: provider).models
    }

    // MARK: - Anthropic

    /// `GET {base}/models?limit=100`, paging on `after_id` while `has_more`.
    ///
    /// Anthropic reports real capability data — an `image_input` leaf and a
    /// `thinking` leaf — which `CatalogRow` folds into the same modality and
    /// ability sets a gateway's flat booleans produce. The context window is
    /// `max_input_tokens`; there is no `context_window` field, and assuming one
    /// from memory is the mistake this comment exists to prevent.
    private func anthropicModels(
        at url: URL,
        provider: ModelProvider,
        secret: String
    ) async throws -> [AIModel] {
        var models: [AIModel] = []
        var after: String?

        for _ in 0..<Self.pageLimit {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var items = [URLQueryItem(name: "limit", value: "100")]
            if let after { items.append(URLQueryItem(name: "after_id", value: after)) }
            components?.queryItems = items
            guard let paged = components?.url else { throw ModelCatalogError.badURL(url.absoluteString) }

            var request = URLRequest(url: paged)
            try await ProviderNetworking.authorize(
                &request, provider: provider, secret: secret,
                omittingEmptyCredential: true
            )

            let page = try Self.parseOpenAIPage(try await get(request), provider: provider)
            models += page.models

            guard page.hasMore, let last = page.lastID else { break }
            after = last
        }

        return models
    }

    // MARK: - Google

    /// `GET {base}/models?pageSize=100`, paging on `nextPageToken`.
    ///
    /// The key goes in the `x-goog-api-key` header rather than the `?key=`
    /// query parameter Google's own examples use. Both work; only one keeps the
    /// key out of anything that logs a URL.
    ///
    /// Filtered to entries that support `generateContent`, because the same
    /// list carries embedding and tuning-only entries that cannot answer a
    /// chat request.
    private func googleModels(
        at url: URL,
        provider: ModelProvider,
        secret: String
    ) async throws -> [AIModel] {
        var models: [AIModel] = []
        var pageToken: String?

        for _ in 0..<Self.pageLimit {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var items = [URLQueryItem(name: "pageSize", value: "100")]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components?.queryItems = items
            guard let paged = components?.url else { throw ModelCatalogError.badURL(url.absoluteString) }

            var request = URLRequest(url: paged)
            try await ProviderNetworking.authorize(
                &request, provider: provider, secret: secret,
                omittingEmptyCredential: true
            )

            let page = try Self.parseGooglePage(try await get(request), provider: provider)
            models += page.models

            guard let next = page.nextPageToken, !next.isEmpty else { break }
            pageToken = next
        }

        return models
    }

    // MARK: - Parsing
    //
    // Split from fetching on purpose. These two are the part with the actual
    // variance in it — see `CatalogRow` — and keeping them static and pure
    // means a recorded response can be run through them without a network, a
    // key, or a live endpoint that may have changed its mind since.

    /// One page of an OpenAI-shaped list. Anthropic uses the same envelope with
    /// cursor fields added, so both go through here.
    static func parseOpenAIPage(
        _ data: Data,
        provider: ModelProvider = ModelProvider(name: "OpenAI")
    ) throws -> CatalogPage {
        guard let envelope = try? JSONDecoder().decode(DataEnvelope<CatalogRow>.self, from: data) else {
            throw ModelCatalogError.decoding
        }
        return CatalogPage(
            models: envelope.rows.map { $0.model(origin: .fetched, provider: provider) },
            hasMore: envelope.hasMore == true,
            lastID: envelope.lastID
        )
    }

    /// One page of the Gemini API's list.
    ///
    /// Entries that cannot answer `generateContent` are dropped — the same list
    /// carries embedding and tuning-only models. An entry that does not say is
    /// kept, since silence is not a refusal.
    static func parseGooglePage(
        _ data: Data,
        provider: ModelProvider = ModelProvider(name: "Google", kind: .google)
    ) throws -> CatalogPage {
        guard let envelope = try? JSONDecoder().decode(GoogleEnvelope.self, from: data) else {
            throw ModelCatalogError.decoding
        }
        return CatalogPage(
            models: envelope.rows
                .filter { $0.supportedGenerationMethods?.contains("generateContent") ?? true }
                .map { $0.model(provider: provider) },
            nextPageToken: envelope.nextPageToken
        )
    }

    // MARK: - Transport

    private func get(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ModelCatalogError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ModelCatalogError.transport(String(localized: "The endpoint did not answer with HTTP."))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ModelCatalogError(status: http.statusCode, body: data)
        }
        return data
    }
}

/// One page of a model list, plus whichever cursor its vendor paginates with.
nonisolated struct CatalogPage: Sendable {
    var models: [AIModel] = []
    var hasMore: Bool = false
    var lastID: String?
    var nextPageToken: String?
}

// MARK: - Wire shapes

/// `{"data": [...]}`, plus Anthropic's cursor fields when they are there.
///
/// `data` is optional on the wire even though every endpoint sends it: Swift's
/// synthesised `init(from:)` ignores property defaults, so a non-optional would
/// turn one absent key into a failed fetch.
nonisolated private struct DataEnvelope<Row: Decodable>: Decodable {
    private var data: [Row]?
    var hasMore: Bool?
    var lastID: String?

    var rows: [Row] { data ?? [] }

    private enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastID = "last_id"
    }
}

/// One row of an OpenAI-shaped `/models` response.
///
/// Every field but `id` is optional, and that is not defensiveness — it is the
/// actual variance. One real response contains both a row carrying name, type,
/// token limits, modalities and capabilities, *and* rows carrying nothing but
/// `{"id", "object", "created", "owned_by"}`. Both have to decode, from one
/// decoder, without either losing what it did send.
///
/// The alias sets exist because the three vendors spell the same two numbers
/// three ways, and gateways pick whichever they grew up with.
nonisolated private struct CatalogRow: Decodable {
    var id: String
    var name: String?
    var displayName: String?
    var ownedBy: String?
    var type: String?
    var created: Double?
    var icon: String?

    var contextLength: Int?
    var maxInputTokens: Int?
    var inputTokenLimit: Int?

    var maxOutputTokens: Int?
    var maxTokens: Int?
    var outputTokenLimit: Int?

    var modalities: Modalities?
    var capabilities: [String: CapabilityValue]?

    private enum CodingKeys: String, CodingKey {
        case id, name, created, icon, type, modalities, capabilities
        case displayName = "display_name"
        case ownedBy = "owned_by"
        case contextLength = "context_length"
        case maxInputTokens = "max_input_tokens"
        case inputTokenLimit = "input_token_limit"
        case maxOutputTokens = "max_output_tokens"
        case maxTokens = "max_tokens"
        case outputTokenLimit = "output_token_limit"
    }

    nonisolated struct Modalities: Decodable {
        var input: [String]?
        var output: [String]?
    }

    /// Builds the model, then hands whatever is still blank to capability resolution.
    ///
    /// `reported` is assembled as it goes, so a server that sent `modalities`
    /// keeps exactly what it sent and a server that sent nothing gets the full
    /// guess. That distinction is the whole reason `ReportedFields` exists.
    func model(origin: AIModel.Origin, provider: ModelProvider) -> AIModel {
        var reported: ReportedFields = []
        var model = AIModel(id: id)

        model.displayName = name ?? displayName ?? ""
        model.ownedBy = ownedBy ?? ""
        model.iconHint = icon ?? ""
        model.createdAt = created.map { Date(timeIntervalSince1970: $0) }
        model.origin = origin
        model.contextLength = contextLength ?? maxInputTokens ?? inputTokenLimit
        model.maxOutputTokens = maxOutputTokens ?? maxTokens ?? outputTokenLimit

        if type != nil {
            reported.insert(.kind)
        }
        model.kind = AIModel.Kind(wire: type)

        if let input = modalities?.input {
            reported.insert(.input)
            model.input = Self.modalitySet(input)
        }
        if let output = modalities?.output {
            reported.insert(.output)
            model.output = Self.modalitySet(output)
        }

        if let capabilities {
            reported.insert(.abilities)
            if Self.flag(capabilities, "tool_call", "tools", "function_call", "function_calling") {
                model.abilities.insert(.toolCall)
            }
            if Self.flag(capabilities, "reasoning", "thinking") {
                model.abilities.insert(.reasoning)
            }
            // Vision arrives two ways — as its own boolean and as `image` in the
            // input modalities — and they mean the same thing. Folding the flag
            // into the modality set here is what lets `AIModel.isVision` be
            // derived instead of stored, so the two can never disagree.
            if Self.flag(capabilities, "vision", "image_input") {
                reported.insert(.input)
                model.input.insert(.image)
            }
        }

        return ModelCapabilityResolver.resolve(
            model: model,
            provider: provider,
            reported: reported
        ).model
    }

    /// Unknown strings are dropped rather than thrown on — this list will meet
    /// gateways that invent modalities, and losing one chip is a better outcome
    /// than losing the whole response.
    private static func modalitySet(_ raw: [String]) -> Set<AIModel.Modality> {
        let parsed = Set(raw.compactMap { AIModel.Modality(rawValue: $0.lowercased()) })
        // An empty result would render as a model that accepts nothing, which
        // is never what a server meant to say.
        return parsed.isEmpty ? [.text] : parsed
    }

    private static func flag(_ capabilities: [String: CapabilityValue], _ names: String...) -> Bool {
        names.contains { capabilities[$0]?.isSupported == true }
    }
}

/// A capability entry, in either of the two shapes that turn up under the same
/// key name: a flat boolean (`"vision": true`) or a node with a `supported`
/// leaf (`"image_input": {"supported": true}`).
///
/// Never throws. An entry that is neither — Anthropic's `thinking.types`, say —
/// decodes as unsupported, which is the right reading of "this endpoint did not
/// tell us".
nonisolated private enum CapabilityValue: Decodable {
    case flag(Bool)
    case node(supported: Bool?)
    case unknown

    var isSupported: Bool {
        switch self {
        case .flag(let value): value
        case .node(let value): value ?? false
        case .unknown: false
        }
    }

    init(from decoder: any Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(Bool.self) {
            self = .flag(value)
            return
        }
        if let container = try? decoder.container(keyedBy: Key.self) {
            self = .node(supported: try? container.decodeIfPresent(Bool.self, forKey: .supported))
            return
        }
        self = .unknown
    }

    private enum Key: String, CodingKey { case supported }
}

/// The Gemini API's own envelope, which differs enough from the OpenAI shape to
/// deserve its own type: the array is `models`, the id lives in `name` behind a
/// `models/` prefix, and `name` therefore cannot mean what it means above.
nonisolated private struct GoogleEnvelope: Decodable {
    private var models: [GoogleModelRow]?
    var nextPageToken: String?

    var rows: [GoogleModelRow] { models ?? [] }
}

nonisolated private struct GoogleModelRow: Decodable {
    var name: String
    var displayName: String?
    var inputTokenLimit: Int?
    var outputTokenLimit: Int?
    var supportedGenerationMethods: [String]?

    func model(provider: ModelProvider) -> AIModel {
        var model = AIModel(id: name.hasPrefix("models/") ? String(name.dropFirst(7)) : name)
        model.displayName = displayName ?? ""
        model.ownedBy = "google"
        model.contextLength = inputTokenLimit
        model.maxOutputTokens = outputTokenLimit
        model.origin = .fetched
        // Google reports token limits and nothing about modality or tools, so
        // everything else comes from the bundled catalog or fallback.
        return ModelCapabilityResolver.resolve(model: model, provider: provider).model
    }
}

/// The error envelope, in the three shapes the vendors send it in.
///
/// Only the fields that identify an authentication failure are modelled. Every
/// one is optional, so a fourth vendor's unknown shape decodes to "no signal"
/// rather than throwing inside error handling.
nonisolated private struct APIErrorBody: Decodable {
    var error: Detail?

    nonisolated struct Detail: Decodable {
        /// Anthropic: `authentication_error`.
        var type: String?
        /// OpenAI: `invalid_api_key`. Google puts an integer here instead,
        /// which is why this is not a `String`.
        var code: Code?
        /// Google: `UNAUTHENTICATED`, or `INVALID_ARGUMENT` with a reason below.
        var status: String?
        var details: [Reason]?
    }

    nonisolated struct Reason: Decodable {
        /// Google: `API_KEY_INVALID`.
        var reason: String?
    }

    /// `code` is a string on one vendor and a number on another.
    nonisolated enum Code: Decodable {
        case text(String)
        case number(Int)

        var text: String? {
            if case .text(let value) = self { return value }
            return nil
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .text(value)
            } else {
                self = .number((try? container.decode(Int.self)) ?? 0)
            }
        }
    }

    static func isAuthenticationFailure(_ body: Data) -> Bool {
        guard let decoded = try? JSONDecoder().decode(APIErrorBody.self, from: body),
            let error = decoded.error
        else { return false }

        if error.type == "authentication_error" { return true }
        if error.code?.text == "invalid_api_key" { return true }
        if error.status == "UNAUTHENTICATED" { return true }
        if error.details?.contains(where: { $0.reason == "API_KEY_INVALID" }) == true { return true }
        return false
    }
}

// MARK: - Errors

/// What went wrong, in words the editor can show as-is.
///
/// No case carries the secret, and none carries the response body verbatim —
/// an endpoint that echoes the key back in an error message must not be the
/// reason it lands on screen.
nonisolated enum ModelCatalogError: Error, LocalizedError, Equatable, Sendable {
    case unauthorized
    case notFound
    case http(Int)
    case transport(String)
    case decoding
    case badURL(String)
    case unsupportedForVertex

    /// Classifies a failure from the status code *and* the body.
    ///
    /// The body is read because the status code is not enough: Google answers a
    /// wrong API key with **400**, not 401, and explains itself only in the
    /// payload. Mapping on status alone reported "The endpoint answered 400."
    /// for the single most common mistake anyone makes with a Gemini key —
    /// found by pointing the real client at the real endpoint with a bad key,
    /// which is why that check is in the verification list rather than left to
    /// a reading of the docs.
    ///
    /// Nothing from the body is shown. It is inspected for known signals and
    /// then dropped, because an endpoint that echoes the key back in an error
    /// message must not be the reason it lands on screen.
    init(status: Int, body: Data) {
        switch status {
        case 401, 403:
            self = .unauthorized
        case 404:
            self = .notFound
        default:
            self = APIErrorBody.isAuthenticationFailure(body) ? .unauthorized : .http(status)
        }
    }

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            String(localized: "The endpoint rejected this key.")
        case .notFound:
            String(localized: "No model list at this address. Check the base URL.")
        case .http(let code):
            String(localized: "The endpoint answered \(code).")
        case .transport(let message):
            message
        case .decoding:
            String(localized: "The endpoint answered, but not with a model list.")
        case .badURL(let value):
            String(localized: "\(value) is not a valid URL.")
        case .unsupportedForVertex:
            String(
                localized:
                    "Vertex lists Model Garden entries rather than the models this project can call. Add the ones you use."
            )
        }
    }
}
