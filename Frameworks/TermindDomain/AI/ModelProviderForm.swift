import AgentKit
import Foundation

/// Form hints are also concrete save defaults, never implicit runtime destinations.
nonisolated extension ModelAPIType {
    public var defaultProviderName: String {
        switch self {
        case .automatic, .chatCompletions, .responses: "OpenAI"
        case .messages: "Anthropic"
        case .generateContent: "Google"
        }
    }

    public var defaultURL: String {
        switch self {
        case .automatic: "https://api.openai.com/v1/responses"
        case .chatCompletions, .responses: "https://api.openai.com/v1"
        case .messages: "https://api.anthropic.com/v1"
        case .generateContent: "https://generativelanguage.googleapis.com/v1beta"
        }
    }
}

nonisolated extension ProviderEndpoint {
    public var withDefaultURL: ProviderEndpoint {
        var value = self
        if value.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value.url = apiType.defaultURL
        }
        return value
    }
}

public nonisolated enum ModelProviderForm {
    public static func normalized(_ provider: ModelProvider, endpoint: ProviderEndpoint) -> (
        provider: ModelProvider, endpoint: ProviderEndpoint
    ) {
        var provider = provider
        let endpoint = endpoint.withDefaultURL
        provider.name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.name = SavedName.resolve(provider.name, default: endpoint.apiType.defaultProviderName)
        provider.models = provider.models.map(\.savingName)
        provider.inferenceURL = endpoint.requestURL
        provider.baseURL = endpoint.baseURL
        provider.apiFormat = endpoint.format
        provider.usesVertex = provider.usesVertex && endpoint.apiType == .generateContent
        provider.vertex.projectID = provider.vertex.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.vertex.location = provider.vertex.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.vertex.location.isEmpty { provider.vertex.location = "global" }
        return (provider, endpoint)
    }

    public static func hasValidAddress(_ provider: ModelProvider) -> Bool {
        if provider.usesVertexEndpoint {
            return isPathIdentifier(provider.vertex.projectID) && isPathIdentifier(provider.vertex.location)
        }
        return isValidURL(provider.inferenceURL)
    }

    public static func isValidURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host, !host.isEmpty
        else { return false }
        return true
    }

    private static func isPathIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            }
    }
}
