import Foundation

public nonisolated enum CommandGenerationError: LocalizedError, Sendable {
    case emptyDraft

    public var errorDescription: String? {
        String(localized: "Type something at the shell prompt before generating a command.")
    }
}

@MainActor
@Observable
public final class CommandGenerationCoordinator {
    public typealias ReadContext = @MainActor @Sendable () async throws -> CommandGeneratorContext
    public typealias IsCurrent = @MainActor @Sendable () -> Bool
    public typealias Generate = @Sendable (CommandGeneratorContext) async throws -> String
    public typealias Insert = @MainActor @Sendable (String) async -> Void

    public private(set) var state = CommandGeneratorState.idle
    public var isRunning: Bool { task != nil }

    private var task: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init() {}

    public func start(
        targetCount: Int,
        readContext: @escaping ReadContext,
        isCurrent: @escaping IsCurrent,
        generate: @escaping Generate,
        insert: @escaping Insert
    ) {
        cancel()
        generation &+= 1
        let generation = generation
        state = .readingDraft
        task = Task { [weak self] in
            do {
                let context = try await readContext()
                try Task.checkCancellation()
                guard !context.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CommandGenerationError.emptyDraft
                }
                guard isCurrent() else { throw CancellationError() }
                self?.state = .generating
                let command = try await Self.withTimeout { try await generate(context) }
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                await insert(command)
                self?.finish(generation: generation, state: .inserted(targetCount: targetCount), after: .seconds(2))
            } catch is CancellationError {
                self?.finishCancellation(generation: generation)
            } catch {
                self?.finish(generation: generation, state: .failed(error.localizedDescription), after: .seconds(3))
            }
        }
    }

    public func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        dismissTask?.cancel()
        dismissTask = nil
        state = .idle
    }

    public func fail(_ message: String) {
        cancel()
        state = .failed(message)
        scheduleDismiss(generation: generation, after: .seconds(3))
    }

    public func replaceStateForPresentation(_ state: CommandGeneratorState) {
        cancel()
        self.state = state
    }

    private func finishCancellation(generation: UInt64) {
        guard self.generation == generation else { return }
        task = nil
        state = .idle
    }

    private func finish(generation: UInt64, state: CommandGeneratorState, after delay: Duration) {
        guard self.generation == generation else { return }
        task = nil
        self.state = state
        scheduleDismiss(generation: generation, after: delay)
    }

    private func scheduleDismiss(generation: UInt64, after delay: Duration) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self?.generation == generation else { return }
            self?.state = .idle
            self?.dismissTask = nil
        }
    }

    private nonisolated static func withTimeout(
        _ operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw CommandGeneratorError.timedOut
            }
            guard let result = try await group.next() else {
                throw CommandGeneratorError.invalidResponse
            }
            group.cancelAll()
            return result
        }
    }
}
