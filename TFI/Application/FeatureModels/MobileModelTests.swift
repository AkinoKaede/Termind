// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import Observation
import TermindPresentation

@MainActor @Observable
final class MobileModelTests {
    typealias Probe = @Sendable (AIModel, ModelProvider, String) async throws -> String
    private(set) var results: [String: String] = [:]
    private(set) var running = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let probe: Probe

    init(probe: @escaping Probe = { try await ChatProbe().run(model: $0, on: $1, secret: $2).summary }) {
        self.probe = probe
    }

    func start(models: [AIModel], provider: ModelProvider, secret: String) {
        cancel()
        let token = generation
        running = true
        for model in models { results[model.id] = String(localized: AppStrings.Settings.waitingProgress) }
        task = Task { [weak self, probe] in
            defer { if self?.generation == token { self?.running = false } }
            for model in models {
                guard let self, generation == token, !Task.isCancelled else { return }
                results[model.id] = String(localized: AppStrings.Settings.testingProgress)
                do {
                    let result = try await probe(model, provider, secret)
                    guard generation == token, !Task.isCancelled else { return }
                    results[model.id] = result
                } catch {
                    guard generation == token, !Task.isCancelled else { return }
                    results[model.id] = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        running = false
        results = [:]
    }
}
