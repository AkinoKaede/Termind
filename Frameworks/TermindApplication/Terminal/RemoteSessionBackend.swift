import Foundation
import Observation
import TermindDomain

public nonisolated struct RemoteSessionLaunch: Sendable {
    public var command: String
    public var attachment: RemoteSessionReference
    public var created: Bool

    public init(command: String, attachment: RemoteSessionReference, created: Bool) {
        self.command = command
        self.attachment = attachment
        self.created = created
    }
}

public nonisolated struct SSHPTYStartupPlan: Sendable {
    public let command: String
    public let runtimeAttachment: RemoteSessionReference?
    public init(command: String, runtimeAttachment: RemoteSessionReference? = nil) {
        self.command = command
        self.runtimeAttachment = runtimeAttachment
    }
}

public nonisolated struct RemoteSessionCommandResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let truncated: Bool
    public init(stdout: String, stderr: String, exitCode: Int32, truncated: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.truncated = truncated
    }
}

public typealias RemoteSessionCommandExecutor = @Sendable (String) async throws -> RemoteSessionCommandResult

public nonisolated struct RemoteSessionCapabilities: Sendable, Equatable {
    public var windowCount: Bool
    public var clientCount: Bool
    public var shellIntegration: Bool
    public init(windowCount: Bool = false, clientCount: Bool = false, shellIntegration: Bool = false) {
        self.windowCount = windowCount
        self.clientCount = clientCount
        self.shellIntegration = shellIntegration
    }
}

public nonisolated struct RemoteSessionBackendRegistry: Sendable {
    public typealias Factory = @Sendable (@escaping RemoteSessionCommandExecutor) -> any RemoteSessionBackend
    private let factories: [SessionPersistenceBackendID: Factory]
    public init(_ factories: [SessionPersistenceBackendID: Factory]) { self.factories = factories }
    public func backend(_ id: SessionPersistenceBackendID, execute: @escaping RemoteSessionCommandExecutor) throws
        -> any RemoteSessionBackend
    {
        guard let factory = factories[id] else { throw RemoteSessionFailure.unsupported }
        return factory(execute)
    }

    /// A failed lookup is unknown, not evidence that the remote session ended.
    public func sessionExists(
        _ reference: RemoteSessionReference, execute: @escaping RemoteSessionCommandExecutor
    ) async throws -> Bool {
        let backend = try backend(reference.backend, execute: execute)
        let sessions = try await backend.sessions()
        return sessions.contains { backend.matches(reference, session: $0) }
    }
}

public nonisolated protocol RemoteSessionBackend: Sendable {
    var id: SessionPersistenceBackendID { get }
    var capabilities: RemoteSessionCapabilities { get }
    func probe() async throws -> RemoteSessionCapabilities
    func sessions() async throws -> [RemoteSessionDescriptor]
    func validate(_ reference: RemoteSessionReference) throws
    func matches(_ reference: RemoteSessionReference, session: RemoteSessionDescriptor) -> Bool
    func create(
        token: UUID, startupCommand: String?, shellIntegration: Bool, environment: [HostEnvironmentVariable]
    ) async throws -> RemoteSessionDescriptor
    func launch(_ attachment: RemoteSessionReference, created: Bool) throws -> RemoteSessionLaunch
    func terminate(_ attachment: RemoteSessionReference) async throws
}

extension RemoteSessionBackend {
    public nonisolated func probe() async throws -> RemoteSessionCapabilities { capabilities }
    public nonisolated func validate(_ reference: RemoteSessionReference) throws {
        guard reference.version == 1, reference.backend == id else { throw RemoteSessionFailure.unsupported }
    }
}

@MainActor
@Observable
public final class RemoteSessionCoordinator {
    public nonisolated struct Prompt: Identifiable, Sendable {
        public let id: UUID
        public var sessions: [RemoteSessionDescriptor]
        public var failure: RemoteSessionFailure?
    }

    public nonisolated enum Selection: Sendable {
        case create
        case attach(RemoteSessionDescriptor)
        case plainShell
        case retry
        case cancel
    }

    public private(set) var prompt: Prompt? {
        didSet { didChangePrompt?(prompt != nil) }
    }
    public var didChangePrompt: (@MainActor (Bool) -> Void)?
    public var attachment: RemoteSessionReference?
    public private(set) var detached = false
    public var requiresSelection = false
    public var didChangeAttachment: (@MainActor (RemoteSessionReference?) -> Void)?
    private var generation = UUID()
    private var continuation: CheckedContinuation<Selection, Never>?
    private var creationToken: UUID?
    private var creationIntent: CreationIntent?

    private struct CreationIntent: Equatable {
        let backend: SessionPersistenceBackendID
        let hostID: UUID
        let endpoint: String
        let username: String
        let command: String?
        let shellIntegration: Bool
        let environment: [HostEnvironmentVariable]
    }

    public init() {}

    public func choose(_ selection: Selection, for id: UUID) {
        guard prompt?.id == id else { return }
        prompt = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: selection)
    }

    public func cancel() {
        generation = UUID()
        if let prompt { choose(.cancel, for: prompt.id) }
    }

    public func cancelSelection(for id: UUID, close: @MainActor () -> Void) {
        guard prompt?.id == id else { return }
        // Cancelling preparation abandons this connection, not a remote session we have not attached to.
        clearAttachment()
        choose(.cancel, for: id)
        // Close synchronously, so the connection generation expires before cancellation is reported.
        close()
    }

    public func markDetached() { detached = true }

    /// Only a verified, successful session end closes the local terminal.
    /// A failed inspection preserves the recovery reference, just like detach.
    public func finishExit(exitCode: Int32, sessionExists: Bool?) -> Bool {
        if sessionExists == false {
            markEnded()
            return exitCode == 0
        }
        markDetached()
        return false
    }

    public func markEnded() {
        detached = false
        requiresSelection = true
        creationToken = nil
        clearAttachment()
    }

    public func clearAttachment() {
        attachment = nil
        didChangeAttachment?(nil)
    }

    public func confirmPlainConnection() async throws {
        cancel()
        let attempt = generation
        let selection = await ask(sessions: [], failure: .unsupported, generation: attempt)
        try check(attempt)
        guard case .plainShell = selection else { throw CancellationError() }
        requiresSelection = false
        creationToken = nil
        clearAttachment()
    }

    public func prepare(
        preferences: SessionPersistencePreferences, registry: RemoteSessionBackendRegistry,
        execute: @escaping RemoteSessionCommandExecutor,
        hostID: UUID, endpoint: String, username: String,
        startupCommand: String?, requiresNewSession: Bool, shellIntegration: Bool,
        environment: [HostEnvironmentVariable] = []
    ) async throws -> SSHPTYStartupPlan? {
        cancel()
        if attachment == nil, !requiresSelection,
            !preferences.enabled || preferences.onConnect == .plainShell
        {
            creationToken = nil
            return nil
        }
        if !preferences.enabled, attachment == nil {
            try await confirmPlainConnection()
            return nil
        }
        while true {
            let service: any RemoteSessionBackend
            do {
                service = try registry.backend(attachment?.backend ?? preferences.backend, execute: execute)
            } catch {
                let attempt = generation
                let selection = await ask(sessions: [], failure: .unsupported, generation: attempt)
                try check(attempt)
                switch selection {
                case .plainShell:
                    clearAttachment()
                    creationToken = nil
                    requiresSelection = false
                    return nil
                case .retry: continue
                default: throw CancellationError()
                }
            }
            let launch = try await prepare(
                service: service, hostID: hostID, endpoint: endpoint, username: username,
                startupCommand: startupCommand, requiresNewSession: requiresNewSession,
                shellIntegration: shellIntegration, onConnect: preferences.onConnect, environment: environment)
            return launch.map { SSHPTYStartupPlan(command: $0.command, runtimeAttachment: $0.attachment) }
        }
    }

    public func prepare(
        service: any RemoteSessionBackend, hostID: UUID, endpoint: String, username: String,
        startupCommand: String?, requiresNewSession: Bool, shellIntegration: Bool,
        onConnect: SessionPersistencePreferences.OnConnect = .ask,
        environment: [HostEnvironmentVariable] = []
    ) async throws -> RemoteSessionLaunch? {
        cancel()
        let attempt = generation
        detached = false
        let intent = CreationIntent(
            backend: service.id, hostID: hostID, endpoint: endpoint, username: username,
            command: startupCommand, shellIntegration: shellIntegration, environment: environment)
        if creationIntent != intent {
            // An uncertain create may be retried, but its ownership capability must never
            // attach a different launch request to an earlier session.
            creationToken = nil
            creationIntent = intent
        }
        if attachment == nil, !requiresSelection, onConnect == .plainShell {
            creationToken = nil
            return nil
        }
        var mustAsk = requiresSelection
        while true {
            try check(attempt)
            var sessions: [RemoteSessionDescriptor] = []
            var capabilities = service.capabilities
            var failure: RemoteSessionFailure?
            do {
                if let saved = attachment, !requiresNewSession { try service.validate(saved) }
                capabilities = try await service.probe()
                try check(attempt)
                sessions = try await service.sessions()
                try check(attempt)
                if let saved = attachment, !requiresNewSession {
                    if saved.version == 1, saved.backend == service.id,
                        saved.hostID == hostID, saved.endpoint == endpoint, saved.username == username,
                        let current = sessions.first(where: { service.matches(saved, session: $0) })
                    {
                        var updated = saved
                        updated.session = current
                        attachment = updated
                        didChangeAttachment?(updated)
                        return try service.launch(updated, created: false)
                    }
                    attachment = nil
                    didChangeAttachment?(nil)
                    requiresSelection = true
                    mustAsk = true
                    failure = saved.version == 1 ? .sessionMissing : .unsupported
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error as? RemoteSessionFailure ?? .commandFailed(error.localizedDescription)
            }
            try check(attempt)
            let selection: Selection
            if !mustAsk, requiresNewSession || onConnect == .createManaged, failure == nil {
                selection = .create
            } else {
                selection = await ask(sessions: sessions, failure: failure, generation: attempt)
            }
            try check(attempt)
            switch selection {
            case .cancel: throw CancellationError()
            case .retry: continue
            case .plainShell:
                attachment = nil
                creationToken = nil
                requiresSelection = false
                didChangeAttachment?(nil)
                return nil
            case .create, .attach:
                do {
                    let session: RemoteSessionDescriptor
                    let token: UUID?
                    if case .attach(let existing) = selection {
                        guard sessions.contains(existing), !requiresNewSession else { continue }
                        session = existing
                        token = nil
                    } else {
                        let owner = creationToken ?? UUID()
                        creationToken = owner
                        session = try await service.create(
                            token: owner, startupCommand: startupCommand,
                            shellIntegration: shellIntegration && capabilities.shellIntegration,
                            environment: environment)
                        token = owner
                    }
                    try check(attempt)
                    let reference = RemoteSessionReference(
                        backend: service.id, session: session, hostID: hostID,
                        endpoint: endpoint, username: username, ownershipToken: token)
                    let result = try service.launch(reference, created: token != nil)
                    attachment = reference
                    creationToken = nil
                    requiresSelection = false
                    didChangeAttachment?(reference)
                    return result
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try check(attempt)
                    let choice = await ask(
                        sessions: [],
                        failure: error as? RemoteSessionFailure ?? .commandFailed(error.localizedDescription),
                        generation: attempt)
                    try check(attempt)
                    if case .plainShell = choice {
                        attachment = nil
                        creationToken = nil
                        requiresSelection = false
                        didChangeAttachment?(nil)
                        return nil
                    }
                    if case .retry = choice { continue }
                    throw CancellationError()
                }
            }
        }
    }

    private func check(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard attempt == generation else { throw CancellationError() }
    }

    private func ask(sessions: [RemoteSessionDescriptor], failure: RemoteSessionFailure?, generation: UUID) async
        -> Selection
    {
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled, self.generation == generation else { return .cancel }
            return await withCheckedContinuation {
                continuation = $0
                prompt = Prompt(id: id, sessions: sessions, failure: failure)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.choose(.cancel, for: id) }
        }
    }
}
