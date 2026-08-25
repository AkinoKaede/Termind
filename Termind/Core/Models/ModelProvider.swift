import Foundation

/// Which wire protocol an endpoint speaks.
///
/// Three, not thirty. OpenRouter, DeepSeek, Groq, Together and Ollama are all
/// `.openAI` with a different base URL, so listing them as kinds would be
/// listing the same protocol five times and then owing an entry to whoever
/// launches next week.
///
/// Ordered the way they are shown, and `.openAI` first because it is both the
/// most common and the one every compatible gateway needs.
nonisolated enum ModelProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case google

    nonisolated var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .google: "Google"
        }
    }

    var symbol: String {
        switch self {
        case .openAI: "circle.hexagongrid"
        case .anthropic: "sparkle"
        case .google: "diamond"
        }
    }

    /// Carries the version segment, exactly as the provider's own documentation
    /// prints it.
    ///
    /// The alternative — storing `https://api.openai.com` and appending `/v1`
    /// ourselves — is the single most common source of "why does my custom
    /// endpoint 404" in clients of this shape, because the user pastes what
    /// their gateway told them to and it ends up doubled or missing.
    var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .google: "https://generativelanguage.googleapis.com/v1beta"
        }
    }

    /// Appended to the base URL to list models. All three spell it the same.
    var modelsPath: String { "/models" }

    /// What the API path field shows as its placeholder.
    ///
    /// `usesResponsesAPI` only moves this for `.openAI`; the parameter is taken
    /// for all three so callers do not have to know which kinds care.
    func defaultAPIPath(usesResponsesAPI: Bool) -> String {
        switch self {
        case .openAI: usesResponsesAPI ? "/responses" : "/chat/completions"
        case .anthropic: "/messages"
        // The only default that needs the token — Google addresses the model in
        // the path rather than in the body.
        case .google: "/models/\(ModelProvider.modelToken):generateContent"
        }
    }
}

/// Google Vertex AI, which is a different way of reaching the same models.
///
/// Not a fourth `ModelProviderKind`, because the request and response bodies are
/// Gemini's — only the address and the credential change. Kept as a stored
/// struct beside a `usesVertex` flag rather than as an `Optional`, so turning
/// the toggle off and on again does not erase a project id that was typed.
nonisolated struct VertexConfig: Hashable, Sendable {
    var projectID: String = ""
    /// `global` or a region such as `us-central1`.
    var location: String = "global"
    /// Where the service account JSON is filed. The JSON holds an RSA private
    /// key, which is a stronger credential than an API key, so it is stored by
    /// reference like every other secret in this app.
    var credentialRef: String = ""
    /// Lifted out of that JSON at import time so the editor can say who it
    /// signed in as without loading the key back into the view layer.
    var clientEmail: String = ""

    /// Regional hosts are prefixed; `global` is not. Getting this backwards
    /// produces a DNS failure rather than an API error, which reads like a
    /// network problem and is not one.
    var host: String {
        let trimmed = location.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "global" else {
            return "aiplatform.googleapis.com"
        }
        return "\(trimmed)-aiplatform.googleapis.com"
    }

    var isComplete: Bool {
        !projectID.trimmingCharacters(in: .whitespaces).isEmpty && !credentialRef.isEmpty
    }
}

/// One configured endpoint: where to send requests, what to authenticate with,
/// and which models it offers.
///
/// Nothing secret is stored here. `credentialRef` is a lookup string — "the key
/// is filed under this name" — exactly as `Identity.credentialRef` is, so
/// neither an API key nor a service account has a path into this struct, and
/// therefore none into SwiftData or CloudKit later.
nonisolated struct ModelProvider: Identifiable, Hashable, Sendable {
    /// The one substitution an API path may contain. Only Google's default
    /// needs it, but any path may use it.
    static let modelToken = "{model}"

    var id: UUID = UUID()
    /// What the user calls this. Free text, because two providers can be the
    /// same kind — "Work OpenAI" and "Personal OpenAI" is an ordinary setup.
    var name: String
    var kind: ModelProviderKind = .openAI
    /// A disabled provider keeps its configuration but stops offering its
    /// models anywhere. Deleting to silence one would mean retyping the key.
    var isEnabled: Bool = true
    /// Blank means `kind.defaultBaseURL`. Blank rather than pre-filled, so the
    /// field reads as an override rather than as something to get right.
    var baseURL: String = ""
    /// Blank means `kind.defaultAPIPath(usesResponsesAPI:)`.
    var apiPath: String = ""
    var credentialRef: String = ""
    /// `.openAI` only: `/responses` instead of `/chat/completions`.
    var usesResponsesAPI: Bool = false
    /// `.google` only.
    var usesVertex: Bool = false
    var vertex: VertexConfig = VertexConfig()
    var models: [AIModel] = []
    var modelsFetchedAt: Date?

    // MARK: - Resolution

    var resolvedBaseURL: String {
        let typed = baseURL.trimmingCharacters(in: .whitespaces)
        let value = typed.isEmpty ? kind.defaultBaseURL : typed
        // A pasted URL very often carries a trailing slash, and every path
        // below starts with one.
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    var resolvedAPIPath: String {
        let typed = apiPath.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return kind.defaultAPIPath(usesResponsesAPI: usesResponsesAPI) }
        return typed.hasPrefix("/") ? typed : "/" + typed
    }

    /// The URL a chat request actually goes to.
    ///
    /// The editor shows this and the client builds from it, so the caption
    /// under the fields cannot drift away from where requests land — which is
    /// the entire point of showing it.
    ///
    /// `model` is optional because the editor has to draw this line before any
    /// model is picked; the token is left in place then, which reads correctly
    /// as "your model id goes here".
    func resolvedRequestURL(model: String? = nil) -> String {
        let modelID = model ?? Self.modelToken

        if usesVertex, kind == .google {
            return "https://\(vertex.host)/v1/projects/\(vertex.projectID)"
                + "/locations/\(vertex.location)/publishers/google/models/\(modelID):generateContent"
        }

        let path = resolvedAPIPath.replacingOccurrences(of: Self.modelToken, with: modelID)
        return resolvedBaseURL + path
    }

    /// Where `Fetch Models` goes. `nil` for Vertex — see `canFetchModels`.
    var resolvedModelsURL: String? {
        guard !(usesVertex && kind == .google) else { return nil }
        return resolvedBaseURL + kind.modelsPath
    }

    // MARK: - State

    var hasCredential: Bool {
        usesVertex && kind == .google ? vertex.isComplete : !credentialRef.isEmpty
    }

    /// Vertex is excluded deliberately, not for lack of an endpoint: its
    /// publisher listing returns Model Garden entries — third-party and
    /// deployable models mixed in — rather than the models this project can
    /// call, so a fetch would fill the list with things that do not work.
    var canFetchModels: Bool {
        guard hasCredential else { return false }
        return !(usesVertex && kind == .google)
    }

    /// What the role pickers and the conversation's model menu offer. An
    /// embedding model in a chat-model picker is noise.
    var chatModels: [AIModel] {
        models.filter { $0.kind == .chat }
    }

    func model(_ id: String) -> AIModel? {
        models.first { $0.id == id }
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return name.lowercased().contains(q)
            || kind.displayName.lowercased().contains(q)
            || resolvedBaseURL.lowercased().contains(q)
    }
}

/// One model on one provider.
///
/// The shape is wider than any single vendor reports, because the same
/// `GET /models` call answers very differently depending on who is behind it: a
/// good gateway sends name, type, modalities, capabilities and token limits,
/// while `api.openai.com` sends an id and an owner. Every field but `id` is
/// therefore optional on the wire, filled by the decoder where the server spoke
/// and by `ModelCapabilityResolver` where it did not.
nonisolated struct AIModel: Identifiable, Hashable, Sendable {
    /// What a request body carries, and what a `AIModelRef` points at. Two
    /// models on one provider cannot share one.
    var id: String
    /// Blank falls back to `id` — see `label`.
    var displayName: String = ""
    /// `owned_by`. The only field the barest rows carry beyond the id, which
    /// makes it the only thing available to group them by.
    var ownedBy: String = ""
    var kind: Kind = .chat
    var input: Set<Modality> = [.text]
    var output: Set<Modality> = [.text]
    var abilities: Set<Ability> = []
    var contextLength: Int?
    var maxOutputTokens: Int?
    /// The vendor brand string a gateway may send (`"Claude"`, `"DeepSeek"`).
    /// Used for the row glyph and nothing else — it is a hint, not an identity.
    var iconHint: String = ""
    var createdAt: Date?
    var origin: Origin = .manual
    /// `nil` follows the built-in model-family rules. A value is an explicit
    /// per-model override and survives catalog refreshes.
    var reasoningProfile: ReasoningProfile?

    var label: String {
        displayName.isEmpty ? id : displayName
    }

    /// Derived rather than stored, because a payload can assert it twice — once
    /// as `capabilities.vision` and once as `image` in `modalities.input` — and
    /// two fields that mean one thing eventually disagree. The decoder folds
    /// the flag into the modality set, and everything reads it from here.
    var isVision: Bool { input.contains(.image) }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return id.lowercased().contains(q)
            || displayName.lowercased().contains(q)
            || ownedBy.lowercased().contains(q)
    }

    /// What a model is *for*. `other` exists so an unrecognised `type` string
    /// can be kept rather than thrown away or silently called a chat model —
    /// this list meets gateways that invent values.
    nonisolated enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case chat, embedding, image, other

        nonisolated var id: String { rawValue }

        var displayName: String {
            switch self {
            case .chat: String(localized: "Chat")
            case .embedding: String(localized: "Embedding")
            case .image: String(localized: "Image")
            case .other: String(localized: "Other")
            }
        }

        /// Lenient on purpose: an unknown string is `.other`, never a throw.
        /// Absent — which is most of the wire — means `.chat`, since that is
        /// what an endpoint that does not classify its models is serving.
        init(wire: String?) {
            guard let wire, !wire.isEmpty else {
                self = .chat
                return
            }
            self = Kind(rawValue: wire.lowercased()) ?? .other
        }
    }

    /// Five, not two. `pdf`, `audio` and `video` all appear in real payloads —
    /// Gemini reports every one of them — and a client that can only say "text
    /// or image" has to discard the difference.
    nonisolated enum Modality: String, Codable, Sendable, CaseIterable, Identifiable {
        case text, image, audio, video, pdf

        nonisolated var id: String { rawValue }

        var displayName: String {
            switch self {
            case .text: String(localized: "Text")
            case .image: String(localized: "Image")
            case .audio: String(localized: "Audio")
            case .video: String(localized: "Video")
            case .pdf: String(localized: "PDF")
            }
        }

        var symbol: String {
            switch self {
            case .text: "text.alignleft"
            case .image: "photo"
            case .audio: "waveform"
            case .video: "film"
            case .pdf: "doc.richtext"
            }
        }
    }

    nonisolated enum Ability: String, Codable, Sendable, CaseIterable, Identifiable {
        case toolCall, reasoning

        nonisolated var id: String { rawValue }

        var displayName: String {
            switch self {
            case .toolCall: String(localized: "Tools")
            case .reasoning: String(localized: "Reasoning")
            }
        }

        var symbol: String {
            switch self {
            case .toolCall: "wrench.and.screwdriver"
            case .reasoning: "brain"
            }
        }
    }

    /// Whether this row came off the wire or was typed. Shown in the editor so
    /// a hand-added model is not silently replaced by the next fetch.
    nonisolated enum Origin: String, Codable, Sendable {
        case fetched, manual
    }
}

/// One explicit entry in a model's custom reasoning profile.
///
/// A blank `wireValue` means "use the provider's ordinary value for this
/// level". Keeping support separate from the value is important: providers
/// such as Gemini use uppercase wire values, while a missing level means the
/// level is unsupported rather than merely unmapped.
nonisolated struct ReasoningLevelMapping: Hashable, Codable, Sendable {
    var isSupported: Bool
    var wireValue: String?

    init(isSupported: Bool = true, wireValue: String? = nil) {
        self.isSupported = isSupported
        self.wireValue = wireValue
    }
}

/// A complete manual override for the seven stable Termind effort levels.
nonisolated struct ReasoningProfile: Hashable, Codable, Sendable {
    var levels: [ReasoningEffort: ReasoningLevelMapping]

    init(levels: [ReasoningEffort: ReasoningLevelMapping] = [:]) {
        self.levels = levels
    }

    func mapping(for effort: ReasoningEffort) -> ReasoningLevelMapping {
        levels[effort] ?? ReasoningLevelMapping(isSupported: false)
    }
}

/// A model, addressed the way every assignment has to address one.
///
/// Two providers can both offer `gpt-5` — one your employer's account, one your
/// own — so a bare model id names a request but not which key pays for it. That
/// is the whole reason this is a pair.
nonisolated struct AIModelRef: Hashable, Codable, Sendable {
    var modelProviderID: ModelProvider.ID
    var modelID: String
}

/// What Termind asks a model to do.
///
/// Three, and the list is short on purpose. A role earns its place by wanting a
/// *materially different* model, not by being a different prompt — titling a
/// conversation and summarising a thread both want "whatever the chat model is,
/// but cheaper", which is a decision the chat picker already expresses. Roles
/// that only ever get set to the same thing are four pickers pretending to be a
/// choice.
///
/// What is left is three jobs with genuinely different requirements: one that
/// holds a conversation, one that has to answer before you finish typing, and
/// one whose whole value is being a *second opinion*.
///
/// None of them is required — see `AIStore.resolve(_:)`.
nonisolated enum AIRole: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The assistant, whether it is answering or acting. One role rather than
    /// two: "chat" and "agent" differ in what tools the turn is given, not in
    /// which model should be behind it, and splitting them would ask the user a
    /// question that has one answer.
    case chat
    case inline
    case securityReview

    nonisolated var id: String { rawValue }

    var displayName: String {
        switch self {
        // Just "Chat", though it covers agent turns too. A label reading
        // "Chat & Agent" implies a second setting exists somewhere.
        case .chat: String(localized: "Chat")
        case .inline: String(localized: "Inline Suggestion")
        case .securityReview: String(localized: "Security Review")
        }
    }

    var detail: String {
        switch self {
        case .chat:
            String(localized: "Used for chat, tools, and the Assistant sidebar.")
        case .inline:
            String(localized: "Suggests one command above the terminal prompt. Choose a fast model.")
        // Names two models outright. This one runs on every command Approve for
        // Me would execute, so it sits in the latency path — a deliberate
        // reasoning model here makes the feature feel broken even when it
        // works, and that is not something a user should have to discover.
        case .securityReview:
            String(
                localized:
                    "Reviews commands before automatic approval. Choose a fast model different from Chat; Same as Chat is not an independent second opinion."
            )
        }
    }

    /// What the picker shows when nothing is assigned.
    ///
    /// Chat says "Automatic" because it resolves to something rather than to
    /// nothing; the rest say what they actually do, which is follow Chat.
    var unsetLabel: String {
        switch self {
        case .chat: String(localized: "Automatic")
        default: String(localized: "Same as Chat")
        }
    }
}
