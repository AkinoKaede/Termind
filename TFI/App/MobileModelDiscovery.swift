import AgentKit
import Foundation
import Observation
import TermindApplication

@MainActor
@Observable
final class MobileModelDiscovery {
    private(set) var candidates: [AIModel] = []
    private(set) var running = false
    var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    typealias Fetch = @Sendable (ModelProvider, String) async throws -> [AIModel]
    private let fetch: Fetch

    init(fetch: @escaping Fetch = { try await ModelCatalogClient().models(for: $0, secret: $1) }) {
        self.fetch = fetch
    }

    func start(ai: AIConfigurationModel, provider: ModelProvider) {
        cancel()
        do {
            let secret = ai.secret(for: provider.effectiveCredentialRef) ?? ""
            if let error = ai.secretStorageError { throw MobileEditorError.message(error) }
            start(provider: provider, secret: secret, isCurrent: { ai.modelProvider(provider.id) == provider })
        } catch { self.error = error.localizedDescription }
    }

    func start(provider: ModelProvider, secret: String, isCurrent: @escaping @MainActor () -> Bool = { true }) {
        cancel()
        let token = generation
        running = true
        error = nil
        task = Task { [weak self, fetch] in
            defer { if self?.generation == token { self?.running = false } }
            do {
                let values = try await fetch(provider, secret)
                guard let self, generation == token, !Task.isCancelled,
                    isCurrent()
                else { return }
                var seen = Set<String>()
                candidates = values.filter { seen.insert($0.id).inserted }
                running = false
            } catch {
                guard let self, generation == token, !Task.isCancelled, isCurrent() else { return }
                self.error = error.localizedDescription
                running = false
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        candidates = []
        error = nil
        running = false
    }
}
