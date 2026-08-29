import Foundation

nonisolated enum ProviderNetworking {
    static func session(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    static func authorize(
        _ request: inout URLRequest,
        provider: ModelProvider,
        secret: String,
        omittingEmptyCredential: Bool = false
    ) async throws {
        switch provider.kind {
        case .openAI:
            if !omittingEmptyCredential || !secret.isEmpty {
                request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            }
        case .anthropic:
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if !omittingEmptyCredential || !secret.isEmpty {
                request.setValue(secret, forHTTPHeaderField: "x-api-key")
            }
        case .google:
            if provider.usesVertex {
                let token = try await GoogleServiceAccountAuth.shared.accessToken(
                    serviceAccountJSON: secret
                )
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } else if !omittingEmptyCredential || !secret.isEmpty {
                request.setValue(secret, forHTTPHeaderField: "x-goog-api-key")
            }
        }
    }
}
