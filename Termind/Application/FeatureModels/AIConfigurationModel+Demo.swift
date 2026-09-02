import AgentKit
import Foundation

// MARK: - Demo data

extension AIConfigurationModel {
    /// Seed data for P0, so the provider, model and MCP surfaces can be
    /// exercised before anything is persisted.
    ///
    /// Same habit as `HostLibraryModel.demo()`: one of each shape, so every state a
    /// row can be in is on screen from the first launch rather than first
    /// appearing in the field. That means an unconfigured provider next to a
    /// working one, a model with rich metadata next to one resolved from the
    /// bundled catalog, and a server that has never connected.
    ///
    /// **No roles are assigned**, deliberately. The interesting behaviour here
    /// is the automatic chain in `resolve(_:)` — the first provider has no
    /// models at all, so it walks past it — and seeding an assignment would put
    /// that out of reach.
    static func demo() -> AIConfigurationModel {
        // The fresh state: added, never finished. Fetch stays disabled until a
        // key exists, which is the first thing anyone needs to see.
        let openAI = ModelProvider(name: "OpenAI", kind: .openAI)

        // The working state. An OpenAI-kind provider pointed somewhere else,
        // which is the whole reason the base URL is editable — a gateway is not
        // a fourth API type.
        let openRouterKey = AIConfigurationModel.makeCredentialRef()
        var openRouter = ModelProvider(
            name: "OpenRouter",
            kind: .openAI,
            baseURL: "https://openrouter.ai/api/v1",
            credentialRef: openRouterKey
        )
        // No `modelsFetchedAt`: nothing has been fetched on a fresh install, and
        // a "Fetched last year" line under a list that looks current reads as a
        // bug rather than as seed data.
        openRouter.models = demoModels

        // Google with Vertex off, so both halves of that toggle are one click
        // apart rather than one of them being unreachable at P0.
        let gemini = ModelProvider(name: "Gemini", kind: .google)

        let mcp = MCPServer(
            name: "Context7",
            transport: .streamableHTTP,
            url: "https://mcp.context7.com/mcp",
            // Off, and with no tools: the never-connected state. A server that
            // arrived already listing tools would imply Termind had talked to it,
            // which on a fresh install it has not.
            isEnabled: false
        )

        let store = AIConfigurationModel(
            modelProviders: [openAI, openRouter, gemini], mcpServers: [mcp],
            persistsSecrets: false
        )
        // A stand-in so the working provider actually looks configured. Gone
        // when the app quits, like every other secret at P0.
        store.setSecret("sk-or-v1-demo-key-not-real", for: openRouterKey)
        return store
    }

    /// Four models covering the range one `/models` response really spans.
    ///
    /// The first three are what a metadata-rich gateway sends — name, type,
    /// modalities, capabilities, token limits — and the fourth is the bare
    /// `{"id", "object", "created", "owned_by"}` row that the *same* response
    /// ends with. Putting both in the demo is the point: the model row has to
    /// read well when the server said everything and when it said almost
    /// nothing.
    private static var demoModels: [AIModel] {
        var deepseek = AIModel(id: "deepseek-v4-pro")
        deepseek.displayName = "DeepSeek V4 Pro"
        deepseek.ownedBy = "deepseek"
        deepseek.iconHint = "DeepSeek"
        deepseek.input = [.text]
        deepseek.output = [.text]
        deepseek.abilities = [.toolCall, .reasoning]
        deepseek.contextLength = 1_000_000
        deepseek.maxOutputTokens = 384_000
        deepseek.origin = .fetched

        var opus = AIModel(id: "claude-opus-5")
        opus.displayName = "Claude Opus 5"
        opus.ownedBy = "anthropic"
        opus.iconHint = "Claude"
        opus.input = [.text, .image, .pdf]
        opus.output = [.text]
        opus.abilities = [.toolCall, .reasoning]
        opus.contextLength = 1_000_000
        opus.maxOutputTokens = 128_000
        opus.origin = .fetched

        // The widest input set anything reports, and the reason `Modality` has
        // five cases instead of the two most clients settle for.
        var gemini = AIModel(id: "gemini-3.1-pro-preview")
        gemini.displayName = "Gemini 3.1 Pro Preview"
        gemini.ownedBy = "google"
        gemini.iconHint = "Gemini"
        gemini.input = [.text, .image, .video, .audio, .pdf]
        gemini.output = [.text]
        gemini.abilities = [.toolCall, .reasoning]
        gemini.contextLength = 1_048_576
        gemini.maxOutputTokens = 65_536
        gemini.origin = .fetched

        // Nothing but an id and an owner, exactly as a bare endpoint sends it.
        // Run through capability resolution so the demo shows what the bundled
        // catalog recovers from only an id.
        var bare = AIModel(id: "o4-mini")
        bare.ownedBy = "openai"
        bare.origin = .fetched

        let provider = ModelProvider(name: "OpenAI")
        return [
            opus,
            gemini,
            deepseek,
            ModelCapabilityResolver.resolve(model: bare, provider: provider).model,
        ]
    }
}
