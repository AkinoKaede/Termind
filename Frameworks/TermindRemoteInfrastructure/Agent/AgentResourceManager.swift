// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindDomain

/// The app lends its existing feature owners, never a second persistence or connection stack.
@MainActor
public final class AgentResourceManager {
    let hosts: (any AgentHostManaging)?
    let credentials: any AgentCredentialManaging
    let snippets: any AgentSnippetManaging
    let forwardings: any AgentForwardingManaging
    let forwardingRuntime: any AgentForwardingControlling
    let metrics: any AgentMetricsManaging
    let defaultKeyStorage: @MainActor () -> KeyStorage
    let defaultPasswordStorage: @MainActor () -> PasswordStorage
    let generateEnclave: @Sendable (String, Bool) throws -> SecureEnclaveKeyMaterial

    public init(
        credentials: any AgentCredentialManaging, snippets: any AgentSnippetManaging,
        forwardings: any AgentForwardingManaging, forwardingRuntime: any AgentForwardingControlling,
        metrics: any AgentMetricsManaging, hosts: (any AgentHostManaging)? = nil,
        defaultKeyStorage: @escaping @MainActor () -> KeyStorage = { .thisDevice },
        defaultPasswordStorage: @escaping @MainActor () -> PasswordStorage = { .thisDevice },
        generateEnclave: @escaping @Sendable (String, Bool) throws -> SecureEnclaveKeyMaterial = {
            try SecureEnclaveKey.generate(comment: $0, requiresUserPresence: $1)
        }
    ) {
        self.credentials = credentials
        self.hosts = hosts
        self.snippets = snippets
        self.forwardings = forwardings
        self.forwardingRuntime = forwardingRuntime
        self.metrics = metrics
        self.defaultKeyStorage = defaultKeyStorage
        self.defaultPasswordStorage = defaultPasswordStorage
        self.generateEnclave = generateEnclave
    }

    func perform(
        _ specification: ResourceToolSpecification, arguments: ResourceToolArguments, broker: SecretBroker
    ) async throws -> AgentJSONValue {
        try Task.checkCancellation()
        switch specification.resource {
        case .host, .hostGroup: return try await manageHost(specification, arguments)
        case .identity: return try await manageIdentity(specification.action, arguments, broker: broker)
        case .key: return try await manageKey(specification.action, arguments, broker: broker)
        case .snippet, .snippetPackage: return try manageSnippet(specification, arguments)
        case .portForwarding: return try manageForwarding(specification.action, arguments)
        case .metrics: return try manageMetrics(specification.action, arguments)
        }
    }

    func snippetCommand(id: UUID, hostID: UUID) throws -> String {
        guard let snippet = snippets.snippets.first(where: { $0.id == id }) else {
            throw ResourceToolError.notFound
        }
        try snippets.requireExecutionHost(hostID)
        return snippet.body
    }
}

extension PortForwardingController: AgentForwardingControlling {
    public func managementStatus(_ id: UUID) -> AgentForwardingStatus {
        switch state(for: id) {
        case .stopped: .init(state: "stopped")
        case .preparing: .init(state: "preparing")
        case .awaitingTrust: .init(state: "awaiting_trust", requiresUserAction: true)
        case .awaitingAuthentication: .init(state: "awaiting_authentication", requiresUserAction: true)
        case .connecting: .init(state: "connecting")
        case .reconnecting: .init(state: "reconnecting")
        case .starting: .init(state: "starting")
        case .running: .init(state: "running")
        case .failed: .init(state: "failed")
        }
    }
}

nonisolated enum ResourceToolError: String, LocalizedError {
    case notFound = "The requested resource does not exist."
    case invalidInput = "Invalid resource configuration or conflicting fields."
    case invalidReference = "A referenced resource is unavailable."
    case unsupported = "This operation is not supported for this resource."
    case credentialFailed =
        "Credential operation failed. Check the input and device availability, then request new handles."
    case saveFailed = "The resource could not be saved."

    var errorDescription: String? { rawValue }
}

/// Null is absence, not deletion. Explicit clears cannot also carry replacement values.
nonisolated struct ResourceToolArguments: Sendable {
    let values: [String: AgentJSONValue]
    let clears: Set<String>

    init(_ value: AgentJSONValue, allowedClears: Set<String> = []) throws {
        guard let object = value.objectValue else { throw ResourceToolError.invalidInput }
        values = object.filter { $0.value != .null }
        let rawClears = values["clear_fields"]?.arrayValue ?? []
        guard rawClears.allSatisfy({ $0.stringValue != nil }) else { throw ResourceToolError.invalidInput }
        clears = Set(rawClears.compactMap(\.stringValue))
        guard clears.isSubset(of: allowedClears),
            clears.allSatisfy({ values[$0] == nil && values["\($0)_secret_handle"] == nil })
        else { throw ResourceToolError.invalidInput }
    }

    func text(_ name: String) -> String? { values[name]?.stringValue }
    func bool(_ name: String) -> Bool? { values[name]?.boolValue }
    func int(_ name: String) -> Int? { values[name]?.integerValue }
    func uuid(_ name: String) throws -> UUID {
        guard let value = text(name), let id = UUID(uuidString: value) else { throw ResourceToolError.invalidInput }
        return id
    }
    func optionalID(_ name: String) throws -> UUID? { try values[name].map { _ in try uuid(name) } }
    func strings(_ name: String) -> [String]? { values[name]?.arrayValue?.compactMap(\.stringValue) }
    func enumValue<T: RawRepresentable>(_ name: String, default fallback: T) throws -> T where T.RawValue == String {
        guard let text = text(name) else { return fallback }
        guard let value = T(rawValue: text) else { throw ResourceToolError.invalidInput }
        return value
    }
}
