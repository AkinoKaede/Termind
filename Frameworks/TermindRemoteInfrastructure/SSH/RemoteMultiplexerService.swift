import Foundation
import TermindApplication
import TermindDomain

/// A single service entry point; command dialects retain their native identity contracts.
public nonisolated struct RemoteMultiplexerService: RemoteSessionBackend {
    public typealias Executor = RemoteSessionCommandExecutor
    public let id: SessionPersistenceBackendID
    private let execute: Executor

    public init(backend: SessionPersistenceBackendID = .tmux, execute: @escaping Executor) {
        id = backend
        self.execute = execute
    }

    private var backend: RemoteMultiplexerBackend {
        get throws {
            guard let kind = RemoteMultiplexerKind(rawValue: id.rawValue) else {
                throw RemoteSessionFailure.unsupported
            }
            return .init(kind: kind, execute: execute)
        }
    }

    public var capabilities: RemoteSessionCapabilities {
        (try? backend.capabilities) ?? .init()
    }

    public func probe() async throws -> RemoteSessionCapabilities { try await backend.probe() }
    public func sessions() async throws -> [RemoteSessionDescriptor] { try await backend.sessions() }
    public func validate(_ reference: RemoteSessionReference) throws { try backend.validate(reference) }
    public func matches(_ reference: RemoteSessionReference, session: RemoteSessionDescriptor) -> Bool {
        (try? backend.matches(reference, session: session)) ?? false
    }
    public func create(
        token: UUID, startupCommand: String?, shellIntegration: Bool, environment: [HostEnvironmentVariable] = []
    ) async throws -> RemoteSessionDescriptor {
        try await backend.create(
            token: token, startupCommand: startupCommand, shellIntegration: shellIntegration, environment: environment)
    }
    public func launch(_ attachment: RemoteSessionReference, created: Bool) throws -> RemoteSessionLaunch {
        try backend.launch(attachment, created: created)
    }
    public func terminate(_ attachment: RemoteSessionReference) async throws { try await backend.terminate(attachment) }
}
