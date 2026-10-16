import Foundation
import Observation
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct HostMACAddressCandidate: Identifiable, Hashable, Sendable {
    public var interface: String
    public var address: MACAddress
    public var id: String { interface + ":" + address.rawValue }
    public init(interface: String, address: MACAddress) {
        self.interface = interface
        self.address = address
    }
}

public nonisolated protocol HostMACAddressResolving: Sendable {
    func resolve(_ request: SSHConnectionRequest, progress: SSHRouteProgressHandler?) async throws
        -> [HostMACAddressCandidate]
}

/// A disposable editor operation. Authentication is memory-only and never saves the draft.
@MainActor
@Observable
public final class HostMACAddressModel {
    public let connection = RemoteSessionConnectionController()
    public private(set) var candidates: [HostMACAddressCandidate] = []
    public private(set) var isFinished = false
    public private(set) var authenticationPrompt: SSHAuthenticationPrompt?
    private let host: Host
    private let library: HostLibraryModel
    private let resolver: any HostMACAddressResolving
    private var submissions: [Host.ID: SSHAuthenticationSubmission]
    private var proxies: [Host.ID: SSHProxyAuthenticationSubmission]
    private var task: Task<Void, Never>?
    private var generation = UUID()

    public init(
        host: Host, library: HostLibraryModel, resolver: any HostMACAddressResolving,
        submissions: [Host.ID: SSHAuthenticationSubmission] = [:],
        proxies: [Host.ID: SSHProxyAuthenticationSubmission] = [:]
    ) {
        self.host = host
        self.library = library
        self.resolver = resolver
        self.submissions = submissions
        self.proxies = proxies
    }

    public func start() {
        guard task == nil else { return }
        generation = UUID()
        let token = generation
        let route = library.route(for: host)
        connection.journey.begin(
            host: host, route: route, purpose: .sshSession, username: library.identity(for: host)?.username)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if let pending = proxies.firstHostRequiringProxyPassword(in: route) {
                    throw TermindSSHError.proxyAuthentication(
                        hostID: pending.id, serverChallenge: false,
                        message: TermindSSHError.missingCredential.localizedDescription)
                }
                if let pending = submissions.firstHostRequiringPassword(in: route) {
                    throw TermindSSHError.routeHost(
                        hostID: pending.id, authentication: true, serverChallenge: false, hostKey: false,
                        message: TermindSSHError.missingCredential.localizedDescription)
                }
                if let pending = submissions.firstHostRequiringPassphrase(
                    in: route, key: library.key, requiresEntry: library.requiresPassphraseEntry)
                {
                    throw TermindSSHError.routeHost(
                        hostID: pending.id, authentication: true, serverChallenge: false, hostKey: false,
                        message: TermindSSHError.keyPassphraseRequired.localizedDescription)
                }
                var preparation = try library.prepareSSHConnection(
                    for: host, submissions: submissions.takeAuthenticationSecrets(),
                    proxySubmissions: proxies.takeProxyAuthenticationSecrets(),
                    temporaryHostKeys: connection.temporaryHostKeys)
                preparation.beforeConnect = nil
                let configuration = try await preparation.resolve(trustPolicy: .allowChallenge)
                defer { configuration.clearSecrets() }
                try Task.checkCancellation()
                let request = SSHConnectionRequest(
                    configuration: configuration,
                    authorizeHostKey: { [weak self] challenge in
                        guard let self else { throw CancellationError() }
                        return try await self.authorize(challenge, token: token)
                    },
                    keyboardInteractive: { [weak self] challenge in
                        guard let self else { throw CancellationError() }
                        return try await self.answer(challenge, token: token)
                    },
                    securityKeySigning: { [weak self] request in
                        guard let self else { throw CancellationError() }
                        return try await self.sign(request, token: token)
                    })
                let values = try await resolver.resolve(
                    request,
                    progress: connection.progressHandler(
                        attemptID: token, isCurrent: { [weak self] in self?.generation == $0 }))
                try Task.checkCancellation()
                guard token == generation else { return }
                candidates = values
                isFinished = true
                connection.disconnect()
                clearSecrets()
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                if let ssh = error as? TermindSSHError,
                    ssh.isLocalAuthenticationRequirement || ssh.shouldRequestAuthentication
                {
                    let target = route.first { $0.id == ssh.routeHostID } ?? host
                    authenticationPrompt =
                        ssh.isProxyAuthentication
                        ? SSHAuthenticationPromptResolver.proxy(
                            for: target, using: library, submission: proxies[target.id],
                            failureMessage: ssh.localizedDescription,
                            mode: ssh.isServerAuthenticationChallenge ? .serverChallenge : .localIdentity)
                        : SSHAuthenticationPromptResolver.host(
                            target, using: library, submission: submissions[target.id],
                            failureMessage: ssh.localizedDescription,
                            mode: ssh.isServerAuthenticationChallenge ? .serverChallenge : .localIdentity)
                    authenticationPrompt?.allowsSaving = false
                    connection.journey.waitForAuthentication(at: target.id, failure: ssh.localizedDescription)
                } else {
                    clearSecrets()
                    connection.journey.fail(error.localizedDescription)
                }
            }
            if token == generation { task = nil }
        }
    }

    public func submit(
        identityID: UUID?, username: String, password: String?, passphrase: String?, keyID: UUID?
    ) {
        guard let prompt = authenticationPrompt, task == nil else { return }
        if prompt.isProxy {
            proxies[prompt.host.id] = .init(username: username, password: password, identityID: identityID)
        } else {
            let identity = identityID.flatMap(library.identity)
            submissions[prompt.host.id] = .init(
                username: identity?.username ?? username, password: password, passphrase: passphrase,
                keyID: identity?.keyID ?? keyID, identityID: identityID)
        }
        authenticationPrompt = nil
        start()
    }

    public func accept(_ observation: SSHHostKeyObservation) {
        _ = connection.useTemporaryHostKey(observation)
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    private func authorize(_ challenge: SSHHostKeyChallenge, token: UUID) async throws -> SSHHostKeyDecision {
        try check(token)
        let decision = await connection.authorizeHostKey(challenge)
        try check(token)
        return decision
    }

    private func answer(_ challenge: SSHKeyboardInteractiveChallenge, token: UUID) async throws -> [String] {
        try check(token)
        let answers = try await connection.answerKeyboardInteractive(challenge)
        try check(token)
        return answers
    }

    private func sign(_ request: SecurityKeySigningRequest, token: UUID) async throws -> SecurityKeyAssertion {
        try check(token)
        let assertion = try await connection.signWithSecurityKey(request)
        try check(token)
        return assertion
    }

    public func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        authenticationPrompt = nil
        isFinished = false
        candidates = []
        clearSecrets()
        connection.disconnect()
    }

    private func clearSecrets() {
        for id in submissions.keys { submissions[id]?.clearSecrets() }
        for id in proxies.keys { proxies[id]?.clearSecrets() }
        submissions.removeAll()
        proxies.removeAll()
    }
}
