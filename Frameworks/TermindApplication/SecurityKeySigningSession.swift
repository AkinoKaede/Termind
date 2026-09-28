import Foundation

/// Owns one form's signing attempt and delivers exactly one response, including cancellation.
@MainActor
@Observable
public final class SecurityKeySigningSession {
    public private(set) var isRunning = false
    public private(set) var isFinished = false
    private var checkedAutomaticStart = false
    private var task: Task<Void, Never>?
    private let sign: @MainActor () async throws -> SecurityKeyAssertion
    private let respond: @MainActor (Result<SecurityKeyAssertion, any Error>) -> Void

    public init(
        sign: @escaping @MainActor () async throws -> SecurityKeyAssertion,
        respond: @escaping @MainActor (Result<SecurityKeyAssertion, any Error>) -> Void
    ) {
        self.sign = sign
        self.respond = respond
    }

    public func startAutomatically() {
        guard !checkedAutomaticStart else { return }
        checkedAutomaticStart = true
        start()
    }

    public func start() {
        guard !isRunning, !isFinished else { return }
        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let assertion = try await sign()
                try Task.checkCancellation()
                finish(.success(assertion))
            } catch {
                finish(.failure(error))
            }
        }
    }

    public func cancel() {
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<SecurityKeyAssertion, any Error>) {
        guard !isFinished else { return }
        isFinished = true
        isRunning = false
        task = nil
        respond(result)
    }
}
