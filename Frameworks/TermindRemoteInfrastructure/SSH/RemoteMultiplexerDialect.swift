// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain

/// The registration boundary for session commands, runtime inspection, and shell pane identity.
nonisolated protocol RemoteMultiplexerDialect: Sendable {
    var id: SessionPersistenceBackendID { get }
    var capabilities: RemoteSessionCapabilities { get }
    var versionArgument: String { get }
    var paneVariable: String? { get }
    func validateVersion(_ output: String) throws
    func validPane(_ value: String) -> Bool
    func backend(execute: @escaping RemoteSessionCommandExecutor) -> any RemoteSessionBackend
    func runtime(
        reference: RemoteSessionReference?, execute: @escaping RemoteSessionCommandExecutor, charset: RemoteCharset
    ) throws -> any RemoteMultiplexerRuntime
    func helper(_ reference: RemoteSessionReference) throws -> String?
}

nonisolated protocol RemoteMultiplexerRuntime: TerminalRuntimeAdapter {
    func draftTarget(
        context: TerminalShellContext, terminal: String, replacing: Bool
    ) async throws -> RemoteMultiplexerDraftTarget
}

nonisolated enum RemoteMultiplexerRegistry {
    static let dialects: [any RemoteMultiplexerDialect] = [
        RemoteTmuxDialect(), RemoteZellijDialect(), RemoteZmxDialect(), RemoteHerdrDialect(),
    ]
    private static let registrations = Dictionary(uniqueKeysWithValues: dialects.map { ($0.id, $0) })

    static func dialect(_ id: SessionPersistenceBackendID) -> (any RemoteMultiplexerDialect)? {
        registrations[id]
    }

    static func socketDialect(_ id: SessionPersistenceBackendID) -> (any RemoteSocketMultiplexerDialect)? {
        dialect(id) as? any RemoteSocketMultiplexerDialect
    }
}

extension RemoteMultiplexerDialect {
    nonisolated func probe(execute: RemoteSessionCommandExecutor) async throws -> RemoteSessionCapabilities {
        let result = try await execute(RemoteMultiplexerCommands.discovery(id) + "\n\"$exe\" \(versionArgument)")
        try RemoteMultiplexerBackend.check(result)
        try validateVersion(result.stdout)
        return capabilities
    }
}

/// Only native differences live here; the socket backend retains framing and ownership orchestration.
nonisolated protocol RemoteSocketMultiplexerDialect: RemoteMultiplexerDialect {
    var list: String { get }
    func parseList(_ text: String) throws -> [RemoteMultiplexerCandidate]
    // Creation receives a validated managed name. Attach/stop/runtimeCommands/writeDraft receive quoted arguments.
    func create(name: String, token: UUID) -> String
    func attach(name: String) -> String
    func stop(name: String) -> String
    func routing(_ identity: RemoteMultiplexerIdentity) throws -> String
    func validRoute(_ identity: RemoteMultiplexerIdentity, name: String) -> Bool
    func validateIdentity(_ identity: RemoteMultiplexerIdentity) throws
    func identityGuard(_ identity: RemoteMultiplexerIdentity, name: String) throws -> String
    func ownershipGuard(_ identity: RemoteMultiplexerIdentity, name: String, token: UUID) throws -> String
    func metadataOwnershipGuard(_ candidate: RemoteMultiplexerCandidate) throws -> String
    func metadataFields(_ candidate: RemoteMultiplexerCandidate) throws -> String
    func prepareAttachment() -> String
    func validateTermination(_ reference: RemoteSessionReference, identity: RemoteMultiplexerIdentity) throws
    func terminationCleanup(_ reference: RemoteSessionReference, identity: RemoteMultiplexerIdentity) throws -> String
    func runtimeCommands(name: String) -> (String, String)
    func activePane(native: String, focus: String, reference: RemoteSessionReference, clientBound: Bool) throws
        -> String?
    func writeDraft(name: String, pane: String, key: String) -> String
    var restoreShellEnvironment: String { get }
}

extension RemoteSocketMultiplexerDialect {
    nonisolated var versionArgument: String { "--version" }
    nonisolated var capabilities: RemoteSessionCapabilities { .init(shellIntegration: true) }
    nonisolated func backend(execute: @escaping RemoteSessionCommandExecutor) -> any RemoteSessionBackend {
        RemoteMultiplexerBackend(dialect: self, execute: execute)
    }
    nonisolated func runtime(
        reference: RemoteSessionReference?, execute: @escaping RemoteSessionCommandExecutor, charset: RemoteCharset
    ) throws -> any RemoteMultiplexerRuntime {
        guard let reference else { throw TerminalRuntimeError.unsupported }
        return RemoteSocketMultiplexerRuntime(reference: reference, execute: execute, charset: charset)
    }
    nonisolated func helper(_ reference: RemoteSessionReference) throws -> String? {
        try RemoteMultiplexerIdentity.decode(reference.session.identity, kind: id).helper
    }
    nonisolated func validateIdentity(_ identity: RemoteMultiplexerIdentity) throws {
        guard !identity.isolated else { throw RemoteSessionFailure.invalidResponse }
    }
    nonisolated func identityGuard(_ identity: RemoteMultiplexerIdentity, name: String) throws -> String { "" }
    nonisolated func ownershipGuard(_ identity: RemoteMultiplexerIdentity, name: String, token: UUID) throws -> String {
        ""
    }
    nonisolated func metadataOwnershipGuard(_ candidate: RemoteMultiplexerCandidate) throws -> String { "" }
    nonisolated func metadataFields(_ candidate: RemoteMultiplexerCandidate) throws -> String { "" }
    nonisolated func prepareAttachment() -> String { "" }
    nonisolated func validateTermination(_ reference: RemoteSessionReference, identity: RemoteMultiplexerIdentity)
        throws
    {}
    nonisolated func terminationCleanup(_ reference: RemoteSessionReference, identity: RemoteMultiplexerIdentity) throws
        -> String
    {
        ""
    }
    nonisolated var restoreShellEnvironment: String { "" }
}

nonisolated struct RemoteMultiplexerVersion {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ output: String, backend: SessionPersistenceBackendID) throws {
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0].lowercased() == backend.rawValue else {
            throw RemoteSessionFailure.invalidResponse
        }
        let components = fields[1].split(separator: ".")
        guard components.count == 3, let major = Int(components[0]), let minor = Int(components[1]),
            let patch = Int(components[2]), major >= 0, minor >= 0, patch >= 0
        else { throw RemoteSessionFailure.unsupported }
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}
