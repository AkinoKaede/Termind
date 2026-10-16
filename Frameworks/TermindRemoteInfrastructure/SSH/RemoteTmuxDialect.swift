import Foundation
import TermindApplication
import TermindDomain

nonisolated struct RemoteTmuxDialect: RemoteMultiplexerDialect {
    let id = SessionPersistenceBackendID.tmux
    let capabilities = RemoteSessionCapabilities(windowCount: true, clientCount: true, shellIntegration: true)
    let versionArgument = "-V"
    let paneVariable: String? = "TMUX_PANE"

    func validateVersion(_ output: String) throws { try RemoteTmuxCommands.validateVersion(output) }
    func validPane(_ value: String) -> Bool { RemoteShellContextRecord.validPane(value) }
    func backend(execute: @escaping RemoteSessionCommandExecutor) -> any RemoteSessionBackend {
        RemoteTmuxBackend(execute: execute)
    }
    func runtime(
        reference: RemoteSessionReference?, execute: @escaping RemoteSessionCommandExecutor, charset: RemoteCharset
    ) throws -> any RemoteMultiplexerRuntime {
        RemoteTmuxRuntimeDialect(execute: execute, charset: charset)
    }
    func helper(_ reference: RemoteSessionReference) throws -> String? { nil }
}

private nonisolated struct RemoteTmuxBackend: RemoteSessionBackend {
    let execute: RemoteSessionCommandExecutor
    private let dialect = RemoteTmuxDialect()
    var id: SessionPersistenceBackendID { dialect.id }
    var capabilities: RemoteSessionCapabilities { dialect.capabilities }

    func probe() async throws -> RemoteSessionCapabilities { try await dialect.probe(execute: execute) }
    func sessions() async throws -> [RemoteSessionDescriptor] {
        let response = try await execute(RemoteTmuxCommands.list)
        try RemoteMultiplexerBackend.check(response)
        return try RemoteTmuxCommands.parseSessions(response.stdout)
    }
    func validate(_ reference: RemoteSessionReference) throws {
        guard reference.version == 1, reference.backend == id else { throw RemoteSessionFailure.unsupported }
        _ = try RemoteTmuxCommands.attach(reference)
    }
    func matches(_ reference: RemoteSessionReference, session: RemoteSessionDescriptor) -> Bool {
        guard (try? validate(reference)) != nil, reference.session.id == session.id,
            let saved = try? TmuxSessionIdentity.decode(reference.session.identity),
            let current = try? TmuxSessionIdentity.decode(session.identity)
        else { return false }
        return saved.created == current.created && saved.serverPID == current.serverPID
            && (reference.ownershipToken.map { current.owner == $0.uuidString } ?? true)
    }
    func create(
        token: UUID, startupCommand: String?, shellIntegration: Bool, environment: [HostEnvironmentVariable]
    ) async throws -> RemoteSessionDescriptor {
        let result = try await execute(
            RemoteTmuxCommands.create(
                token: token, startupCommand: startupCommand, shellIntegration: shellIntegration,
                environment: environment))
        try RemoteMultiplexerBackend.check(result)
        let confirmed = try RemoteTmuxCommands.parseSessions(result.stdout)
        guard confirmed.count == 1, let session = confirmed.first,
            try TmuxSessionIdentity.decode(session.identity).owner == token.uuidString
        else { throw RemoteSessionFailure.ownershipMismatch }
        return session
    }
    func launch(_ reference: RemoteSessionReference, created: Bool) throws -> RemoteSessionLaunch {
        try validate(reference)
        return .init(command: try RemoteTmuxCommands.attach(reference), attachment: reference, created: created)
    }
    func terminate(_ reference: RemoteSessionReference) async throws {
        try validate(reference)
        guard reference.isManaged else { throw RemoteSessionFailure.ownershipMismatch }
        let result = try await execute(RemoteTmuxCommands.terminate(reference))
        try RemoteMultiplexerBackend.check(result)
        guard result.stdout == "TERMIND_ENDED\n" else { throw RemoteSessionFailure.ownershipMismatch }
    }
}
