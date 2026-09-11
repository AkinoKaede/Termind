import AgentKit
import Foundation
import TermindApplication
import TermindDomain

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
        // The fresh state: added, never finished. With no URL it reads as
        // "Needs a URL", which is the first thing anyone has to see.
        let unfinished = ModelProvider(name: "Local")

        // The working state, and the one that shows why the URL is a single
        // field: a base address with no endpoint on it, resolved to Chat
        // Completions because nothing in it said otherwise.
        let gatewayKey = AIConfigurationModel.makeCredentialRef()
        let gatewayEndpoint = ProviderEndpoint(url: "https://ai.termind.akinokaede.com/v1")
        var gateway = ModelProvider(
            name: "Gateway",
            apiFormat: gatewayEndpoint.format,
            inferenceURL: gatewayEndpoint.requestURL,
            baseURL: gatewayEndpoint.baseURL,
            credentialRef: gatewayKey
        )
        // No `modelsFetchedAt`: nothing has been fetched on a fresh install, and
        // a "Fetched last year" line under a list that looks current reads as a
        // bug rather than as seed data.
        gateway.models = demoModels

        // A second shape, so the API Type column is not one value repeated —
        // and one recognised from the URL's own suffix rather than picked.
        let workEndpoint = ProviderEndpoint(
            url: "https://ai.termind.akinokaede.com/anthropic/v1/messages"
        )
        let work = ModelProvider(
            name: "Work",
            apiFormat: workEndpoint.format,
            inferenceURL: workEndpoint.requestURL,
            baseURL: workEndpoint.baseURL
        )

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
            modelProviders: [unfinished, gateway, work],
            endpoints: [gateway.id: gatewayEndpoint, work.id: workEndpoint],
            mcpServers: [mcp],
            persistsSecrets: false
        )
        // A stand-in so the working provider actually looks configured. Gone
        // when the app quits, like every other secret at P0.
        store.setSecret("demo-key-not-real", for: gatewayKey)
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

        let provider = ModelProvider(name: "Gateway")
        return [
            opus,
            gemini,
            deepseek,
            ModelCapabilityResolver.resolve(model: bare, provider: provider).model,
        ]
    }
}
