import Foundation

/// Which fields a `/models` response actually carried for one row. Resolution
/// fills only fields absent from this set.
nonisolated struct ReportedFields: OptionSet, Sendable {
    let rawValue: Int

    static let kind = ReportedFields(rawValue: 1 << 0)
    static let input = ReportedFields(rawValue: 1 << 1)
    static let output = ReportedFields(rawValue: 1 << 2)
    static let abilities = ReportedFields(rawValue: 1 << 3)
}

/// Resolves both model capabilities and reasoning-effort behavior.
///
/// Resolution order is deliberately narrow and deterministic:
///
/// 1. Fields explicitly reported by `/models` are preserved.
/// 2. A matching record in the bundled Pi catalog fills missing fields.
/// 3. Unknown/custom models use conservative family heuristics.
///
/// A model's manual `reasoningProfile` replaces only the effort mapping. The
/// model editor remains the authority for manually changing capabilities.
nonisolated enum ModelCapabilityResolver {
    struct Resolution: Hashable, Sendable {
        var model: AIModel
        var reasoning: ReasoningResolution
        var catalogSource: CatalogSource?

        var supported: [ReasoningEffort] { reasoning.supported }

        func wireValue(for effort: ReasoningEffort) -> String? {
            reasoning.wireValue(for: effort)
        }

        func clamp(_ requested: ReasoningEffort) -> ReasoningEffort {
            reasoning.clamp(requested)
        }
    }

    struct CatalogSource: Hashable, Sendable {
        var provider: String
        var modelID: String
    }

    struct ReasoningResolution: Hashable, Sendable {
        var supported: [ReasoningEffort]
        private var wireValues: [ReasoningEffort: String]

        init(
            supported: [ReasoningEffort],
            wireValues: [ReasoningEffort: String] = [:]
        ) {
            self.supported = supported
            self.wireValues = wireValues
        }

        func wireValue(for effort: ReasoningEffort) -> String? {
            guard supported.contains(effort) else { return nil }
            return wireValues[effort] ?? (effort == .off ? nil : effort.wireName)
        }

        /// Pi-compatible clamp: prefer the next stronger supported level, then
        /// walk downward when no stronger level exists.
        func clamp(_ requested: ReasoningEffort) -> ReasoningEffort {
            if supported.contains(requested) { return requested }
            guard let requestedIndex = ReasoningEffort.allCases.firstIndex(of: requested) else {
                return supported.first ?? .off
            }
            for effort in ReasoningEffort.allCases.dropFirst(requestedIndex + 1)
            where supported.contains(effort) {
                return effort
            }
            for effort in ReasoningEffort.allCases[..<requestedIndex].reversed()
            where supported.contains(effort) {
                return effort
            }
            return supported.first ?? .off
        }
    }

    struct CatalogMetadata: Hashable, Sendable {
        var package: String
        var version: String
        var commit: String
        var modelCount: Int
    }

    static var catalogMetadata: CatalogMetadata? {
        catalog.metadata
    }

    /// Fills only fields the endpoint did not report and returns the effort
    /// resolution derived from that final model in the same operation.
    static func resolve(
        model: AIModel,
        provider: ModelProvider,
        reported: ReportedFields = []
    ) -> Resolution {
        let record = catalog.record(modelID: model.id, provider: provider)
        let resolvedModel: AIModel
        if let record {
            resolvedModel = fill(model, reported: reported, from: record)
        } else {
            resolvedModel = Fallback.fill(model, reported: reported)
        }
        return Resolution(
            model: resolvedModel,
            reasoning: reasoning(model: resolvedModel, provider: provider, record: record),
            catalogSource: record.map { CatalogSource(provider: $0.provider, modelID: $0.id) }
        )
    }

    /// Resolves efforts without rewriting capabilities. UI callers use this so
    /// a capability the user switched off in Settings stays switched off.
    static func reasoning(
        model: AIModel,
        provider: ModelProvider
    ) -> ReasoningResolution {
        reasoning(
            model: model,
            provider: provider,
            record: catalog.record(modelID: model.id, provider: provider)
        )
    }

    static func customProfile(from resolution: ReasoningResolution) -> ReasoningProfile {
        var levels: [ReasoningEffort: ReasoningLevelMapping] = [:]
        for effort in ReasoningEffort.allCases {
            levels[effort] = ReasoningLevelMapping(
                isSupported: resolution.supported.contains(effort),
                wireValue: resolution.wireValue(for: effort)
            )
        }
        return ReasoningProfile(levels: levels)
    }

    static func customProfile(from resolution: Resolution) -> ReasoningProfile {
        customProfile(from: resolution.reasoning)
    }

    private static func fill(
        _ model: AIModel,
        reported: ReportedFields,
        from record: CatalogRecord
    ) -> AIModel {
        var result = model
        if result.displayName.isEmpty { result.displayName = record.name }
        if result.ownedBy.isEmpty { result.ownedBy = record.provider }
        if !reported.contains(.kind) { result.kind = .chat }
        if !reported.contains(.input) {
            let modalities = Set(record.input.compactMap(AIModel.Modality.init(rawValue:)))
            result.input = modalities.isEmpty ? [.text] : modalities
        }
        if !reported.contains(.output) {
            let modalities = Set(
                (record.output ?? [AIModel.Modality.text.rawValue])
                    .compactMap(AIModel.Modality.init(rawValue:))
            )
            result.output = modalities.isEmpty ? [.text] : modalities
        }
        if !reported.contains(.abilities) {
            if let abilities = record.abilities {
                result.abilities = Set(abilities.compactMap(AIModel.Ability.init(rawValue:)))
            } else {
                // Pi's language-model catalog is consumed by an agent runtime and
                // its provider APIs accept tool schemas. `reasoning` is the one
                // model-specific ability Pi records explicitly.
                result.abilities = [.toolCall]
                if record.reasoning { result.abilities.insert(.reasoning) }
            }
        }
        // Outside every branch above, and that is the point. Server-side search
        // is not treated as a headline capability by anyone: no `/models`
        // payload reports it and Pi's catalog has no field for it, so "the
        // source listed abilities" never means "the source ruled search out".
        // Gating this on silence about *other* abilities would leave it off for
        // exactly the well-described models most likely to have it.
        //
        // Additive only. It can turn the ability on from the model id; it never
        // takes away one the payload actually asserted.
        if Fallback.hasWebSearch(model.id) { result.abilities.insert(.webSearch) }
        if result.contextLength == nil { result.contextLength = record.contextWindow }
        if result.maxOutputTokens == nil, let maxOutputTokens = record.maxOutputTokens {
            result.maxOutputTokens = maxOutputTokens
        }
        return result
    }

    private static func reasoning(
        model: AIModel,
        provider: ModelProvider,
        record: CatalogRecord?
    ) -> ReasoningResolution {
        guard model.abilities.contains(.reasoning) else {
            return ReasoningResolution(supported: [.off])
        }

        let automatic = automaticReasoning(record: record, provider: provider)
        guard let profile = model.reasoningProfile else { return automatic }

        let supported = ReasoningEffort.allCases.filter {
            profile.mapping(for: $0).isSupported
        }
        guard !supported.isEmpty else { return ReasoningResolution(supported: [.off]) }

        var values: [ReasoningEffort: String] = [:]
        for effort in supported {
            let customValue = profile.mapping(for: effort).wireValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let customValue, !customValue.isEmpty {
                values[effort] = customValue
            } else if let automaticValue = automatic.wireValue(for: effort) {
                values[effort] = automaticValue
            } else if effort != .off {
                values[effort] = defaultWireValue(for: effort, provider: provider)
            }
        }
        return ReasoningResolution(supported: supported, wireValues: values)
    }

    private static func automaticReasoning(
        record: CatalogRecord?,
        provider: ModelProvider
    ) -> ReasoningResolution {
        guard let record, record.reasoning else {
            let supported: [ReasoningEffort] = [.off, .minimal, .low, .medium, .high]
            let values = Dictionary(uniqueKeysWithValues: supported.compactMap { effort in
                effort == .off ? nil : (effort, defaultWireValue(for: effort, provider: provider))
            })
            return ReasoningResolution(supported: supported, wireValues: values)
        }

        var supported: [ReasoningEffort]
        if let declared = record.supportedEfforts {
            let declaredSet = Set(declared.compactMap(ReasoningEffort.init(piName:)))
            supported = ReasoningEffort.allCases.filter(declaredSet.contains)
        } else {
            let unsupported = Set(
                (record.unsupportedEfforts ?? []).compactMap(ReasoningEffort.init(piName:))
            )
            supported = ReasoningEffort.allCases.filter { effort in
                if unsupported.contains(effort) { return false }
                if effort == .xHigh || effort == .max {
                    return record.effortWireValues[effort.piName] != nil
                }
                return true
            }
        }
        if supported.isEmpty { supported = [.off] }

        var values: [ReasoningEffort: String] = [:]
        for (name, value) in record.effortWireValues {
            if let effort = ReasoningEffort(piName: name), supported.contains(effort) {
                values[effort] = value
            }
        }
        return ReasoningResolution(supported: supported, wireValues: values)
    }

    private static func defaultWireValue(
        for effort: ReasoningEffort,
        provider: ModelProvider
    ) -> String {
        provider.kind == .google ? effort.wireName.uppercased() : effort.wireName
    }

    // MARK: - Bundled Pi catalog

    private static let catalog = PiModelCatalog.load()

    private struct PiModelCatalog: Sendable {
        var recordsByKey: [String: CatalogRecord]
        var recordsByID: [String: [CatalogRecord]]
        var metadata: CatalogMetadata?

        static func load() -> PiModelCatalog {
            let bundles = [Bundle.main, Bundle(for: BundleToken.self)]
            let piURL = bundles.lazy.compactMap {
                $0.url(forResource: "PiModelCatalog", withExtension: "json")
                    ?? $0.url(
                        forResource: "PiModelCatalog",
                        withExtension: "json",
                        subdirectory: "Resources"
                    )
            }.first
            guard let piURL,
                let data = try? Data(contentsOf: piURL),
                let payload = try? JSONDecoder().decode(PiCatalogPayload.self, from: data)
            else {
                return PiModelCatalog(recordsByKey: [:], recordsByID: [:], metadata: nil)
            }

            var byKey: [String: CatalogRecord] = [:]
            var byID: [String: [CatalogRecord]] = [:]
            func upsert(_ record: CatalogRecord) {
                let recordKey = key(provider: record.provider, modelID: record.id)
                let normalizedID = normalized(record.id)
                byKey[recordKey] = record
                byID[normalizedID, default: []].removeAll {
                    key(provider: $0.provider, modelID: $0.id) == recordKey
                }
                byID[normalizedID, default: []].append(record)
            }

            for record in payload.models {
                upsert(record)
            }

            let overridesURL = bundles.lazy.compactMap {
                $0.url(forResource: "ModelCatalogOverrides", withExtension: "json")
                    ?? $0.url(
                        forResource: "ModelCatalogOverrides",
                        withExtension: "json",
                        subdirectory: "Resources"
                    )
            }.first
            if let overridesURL,
                let overridesData = try? Data(contentsOf: overridesURL),
                let overrides = try? JSONDecoder().decode(
                    CatalogOverridesPayload.self,
                    from: overridesData
                )
            {
                for record in overrides.models {
                    upsert(record)
                }
            }
            return PiModelCatalog(
                recordsByKey: byKey,
                recordsByID: byID,
                metadata: CatalogMetadata(
                    package: payload.package,
                    version: payload.version,
                    commit: payload.commit,
                    modelCount: payload.models.count
                )
            )
        }

        func record(modelID: String, provider: ModelProvider) -> CatalogRecord? {
            let normalizedID = Self.normalized(modelID)
            let preferredProvider = Self.piProviderID(for: provider)

            if let preferredProvider,
                let exact = recordsByKey[Self.key(provider: preferredProvider, modelID: normalizedID)]
            {
                return exact
            }

            let exactCandidates = recordsByID[normalizedID] ?? []
            if let preferredProvider,
                let preferred = exactCandidates.first(where: { $0.provider == preferredProvider })
            {
                return preferred
            }
            if let direct = Self.directVendorRecord(in: exactCandidates, modelID: normalizedID) {
                return direct
            }
            return exactCandidates.sorted { $0.provider < $1.provider }.first
        }

        private static func directVendorRecord(
            in records: [CatalogRecord],
            modelID: String
        ) -> CatalogRecord? {
            let namespace = modelID.split(separator: "/", maxSplits: 1).first.map(String.init)
            let aliases: [String: String] = [
                "openai": "openai",
                "anthropic": "anthropic",
                "google": "google",
                "deepseek": "deepseek",
                "mistralai": "mistral",
                "x-ai": "xai",
            ]
            if let namespace, let provider = aliases[namespace],
                let direct = records.first(where: { $0.provider == provider })
            {
                return direct
            }
            let preferred = ["openai", "anthropic", "google", "deepseek", "mistral", "xai"]
            return preferred.lazy.compactMap { provider in
                records.first(where: { $0.provider == provider })
            }.first
        }

        private static func piProviderID(for provider: ModelProvider) -> String? {
            let url = provider.resolvedBaseURL.lowercased()
            let hosts: [(String, String)] = [
                ("openrouter.ai", "openrouter"),
                ("api.deepseek.com", "deepseek"),
                ("api.groq.com", "groq"),
                ("api.mistral.ai", "mistral"),
                ("api.x.ai", "xai"),
                ("api.moonshot.ai", "moonshotai"),
            ]
            if let match = hosts.first(where: { url.contains($0.0) }) { return match.1 }
            switch provider.kind {
            case .anthropic: return "anthropic"
            case .google: return provider.usesVertex ? "google-vertex" : "google"
            case .openAI:
                return url.contains("api.openai.com") ? "openai" : nil
            }
        }

        private static func normalized(_ modelID: String) -> String {
            let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return id.hasPrefix("~") ? String(id.dropFirst()) : id
        }

        private static func key(provider: String, modelID: String) -> String {
            "\(provider.lowercased())\u{0}\(modelID.lowercased())"
        }
    }

    private struct PiCatalogPayload: Decodable, Sendable {
        var package: String
        var version: String
        var commit: String
        var models: [CatalogRecord]
    }

    private struct CatalogOverridesPayload: Decodable, Sendable {
        var models: [CatalogRecord]
    }

    private struct CatalogRecord: Decodable, Sendable {
        var provider: String
        var id: String
        var name: String
        var reasoning: Bool
        var input: [String]
        var output: [String]?
        var abilities: [String]?
        var contextWindow: Int
        var maxOutputTokens: Int?
        var supportedEfforts: [String]?
        var unsupportedEfforts: [String]?
        var effortWireValues: [String: String] = [:]
    }

    private final class BundleToken: NSObject {}

    // MARK: - Unknown-model fallback

    private enum Fallback {
        static func fill(_ model: AIModel, reported: ReportedFields) -> AIModel {
            var result = model
            let id = model.id.lowercased()

            if embedding.matches(id) {
                if !reported.contains(.kind) { result.kind = .embedding }
                if !reported.contains(.input) { result.input = [.text] }
                if !reported.contains(.output) { result.output = [.text] }
                if !reported.contains(.abilities) { result.abilities = [] }
                return result
            }
            if imageGeneration.matches(id) {
                if !reported.contains(.kind) { result.kind = .image }
                if !reported.contains(.input) { result.input = [.text, .image] }
                if !reported.contains(.output) { result.output = [.text, .image] }
                if !reported.contains(.abilities) { result.abilities = [] }
                return result
            }
            if !reported.contains(.input), vision.matches(id) { result.input.insert(.image) }
            if !reported.contains(.abilities) {
                if tools.matches(id) { result.abilities.insert(.toolCall) }
                if reasoning.matches(id) { result.abilities.insert(.reasoning) }
            }
            // Outside the guard, for the reason given in `fill`. It sits after
            // the embedding and image-generation returns above rather than
            // before them, so neither can pick up a search ability on its way
            // out.
            if webSearch.matches(id) { result.abilities.insert(.webSearch) }
            return result
        }

        static func hasWebSearch(_ modelID: String) -> Bool {
            webSearch.matches(modelID.lowercased())
        }

        private static let embedding = Pattern(
            #"(^|[-_/])embed(ding)?s?([-._/]|$)|text-embedding"#
        )
        private static let imageGeneration = Pattern(
            #"dall-?e|(^|[-_/])image([-._/]|$)|-image-|(^|[-_/])flux([-._/]|$)"#
        )
        private static let vision = Pattern(
            #"gpt-4o|gpt-4\.1|gpt-4-turbo|gpt-[5-9]|(^|[-_/])o[1-9]([-._/]|$)|gemini|claude"#
                + #"|grok-[3-9]|kimi-k[2-9]|qwen.*-vl|llava|pixtral|internvl|step-3|llama-4"#
        )
        private static let tools = Pattern(
            #"gpt-4o|gpt-4\.1|gpt-4-turbo|gpt-[5-9]|gpt-oss|(^|[-_/])o[1-9]([-._/]|$)|gemini|claude"#
                + #"|grok-[3-9]|kimi-k[2-9]|qwen-?[3-9]|glm-[4-9]|minimax-m[2-9]|mistral|llama-[34]"#
                + #"|deepseek-(chat|v[3-9]|reasoner)|command-r|nova-(lite|pro)|step-3|internlm|intern-s1"#
        )
        /// Deliberately the narrowest of these patterns.
        ///
        /// The others answer "can this model probably do X" and an over-guess
        /// costs a greyed-out tick box. This one decides whether a *server
        /// tool* goes into the request body, and an over-guess costs a 400 on
        /// every message. Only families with a shipped, current-shape search
        /// tool are listed: Gemini 1.5's `googleSearchRetrieval` is a different
        /// object and is excluded rather than approximated.
        ///
        /// DeepSeek v4 belongs here despite being reached as an OpenAI-shaped
        /// endpoint: its `/responses` accepts the identical
        /// `{"type": "web_search"}` and answers with the identical
        /// `web_search_call` items, so it needs no code of its own — only to be
        /// recognised. `ModelProvider.supportsNativeWebSearch` still requires
        /// the Responses toggle, which is what keeps the older
        /// `deepseek-chat`/`deepseek-reasoner` chat-completions path out.
        private static let webSearch = Pattern(
            #"gpt-4o|gpt-4\.1|gpt-[5-9]|(^|[-_/])o[3-9]([-._/]|$)"#
                + #"|claude-(opus|sonnet|haiku)-[4-9]|claude-3[-.][57]"#
                + #"|gemini-(2\.[05]|[3-9])"#
                + #"|deepseek-v[4-9]"#
        )
        private static let reasoning = Pattern(
            #"gpt-[5-9]|gpt-oss|(^|[-_/])o[1-9]([-._/]|$)|gemini-(2\.5|[3-9])"#
                + #"|claude-(opus|sonnet|haiku)-[4-9]|claude-3[-.]7"#
                + #"|grok-[3-9]|kimi-k[2-9]|qwen-?[3-9]|glm-[4-9]|minimax-m[2-9]"#
                + #"|deepseek-(r1|v3\.[1-9]|v[4-9]|reasoner)|qwq|magistral|seed-thinking|intern-s1"#
        )

        private struct Pattern {
            private let regex: NSRegularExpression?

            init(_ pattern: String) {
                regex = try? NSRegularExpression(pattern: pattern)
            }

            func matches(_ lowercasedID: String) -> Bool {
                guard let regex else { return false }
                let range = NSRange(lowercasedID.startIndex..., in: lowercasedID)
                return regex.firstMatch(in: lowercasedID, range: range) != nil
            }
        }
    }
}

private extension ReasoningEffort {
    nonisolated init?(piName: String) {
        switch piName {
        case "off": self = .off
        case "minimal": self = .minimal
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        case "xhigh": self = .xHigh
        case "max": self = .max
        default: return nil
        }
    }

    nonisolated var piName: String {
        self == .xHigh ? "xhigh" : rawValue
    }

    nonisolated var wireName: String { piName }
}
