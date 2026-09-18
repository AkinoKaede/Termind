import Foundation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

public nonisolated enum PortForwardingRuntimeState: Hashable, Sendable {
    case stopped
    case preparing
    case awaitingTrust
    case awaitingAuthentication
    case connecting
    case starting
    case running(activeConnections: Int)
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .stopped, .failed: false
        default: true
        }
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .stopped: String(localized: "Stopped")
        case .preparing: String(localized: "Preparing")
        case .awaitingTrust: String(localized: "Awaiting trust")
        case .awaitingAuthentication: String(localized: "Awaiting authentication")
        case .connecting: String(localized: "Connecting")
        case .starting: String(localized: "Starting")
        case .running(let count):
            count == 0
                ? String(localized: "Running")
                : count == 1
                    ? String(localized: "Running · 1 connection")
                    : String(localized: "Running · \(count) connections")
        case .failed(let message): message
        }
    }
}

/// A host's manually opened transport and its shared authentication surface.
@Observable
public final class PortForwardingConnection {
    public let hostID: Host.ID
    public let connection = RemoteSessionConnectionController()
    public var journey: ConnectionJourney { connection.journey }
    public private(set) var authenticationPrompt: SSHAuthenticationPrompt?
    public fileprivate(set) var hostKeyRequestID: UUID?
    fileprivate var route: [Host]
    fileprivate var submissions: [Host.ID: SSHAuthenticationSubmission] = [:]
    fileprivate var attemptID: UUID?
    fileprivate var session: (any SSHForwardingSessionProtocol)?
    fileprivate var task: Task<Void, Never>?
    fileprivate var connected = false

    fileprivate init(host: Host, route: [Host]) {
        hostID = host.id
        self.route = route
    }

    fileprivate func setPrompt(_ prompt: SSHAuthenticationPrompt?) { authenticationPrompt = prompt }
}

/// Runtime intent exists only between explicit Start and Stop/failure. No defaults or retry timers.
@Observable
public final class PortForwardingController {
    public typealias SessionFactory =
        @MainActor (
            @escaping SSHForwardingSession.ConnectionHandler, @escaping SSHForwardingSession.FailureHandler
        ) -> any SSHForwardingSessionProtocol

    private let hosts: HostLibraryModel
    private let makeSession: SessionFactory
    public private(set) var states: [PortForwardingRule.ID: PortForwardingRuntimeState] = [:]
    private var connections: [Host.ID: PortForwardingConnection] = [:]
    private var presentations: [PortForwardingRule.ID: PortForwardingConnection] = [:]
    private var generations: [PortForwardingRule.ID: UUID] = [:]
    private var ruleTasks: [PortForwardingRule.ID: Task<Void, Never>] = [:]
    private var savingAuthentication: PortForwardingConnection?

    public init(
        hosts: HostLibraryModel,
        makeSession: @escaping SessionFactory = {
            SSHForwardingSession(connectionHandler: $0, failureHandler: $1)
        }
    ) {
        self.hosts = hosts
        self.makeSession = makeSession
    }

    public func state(for id: PortForwardingRule.ID) -> PortForwardingRuntimeState { states[id] ?? .stopped }
    public func connection(for id: PortForwardingRule.ID) -> PortForwardingConnection? { presentations[id] }

    public func start(_ id: PortForwardingRule.ID) {
        guard !state(for: id).isActive, let rule = hosts.portForwarding(id), rule.isValid,
            let host = hosts.host(rule.hostID)
        else { return }
        let context: PortForwardingConnection
        if let existing = connections[host.id], !activeIDs(existing).isEmpty {
            context = existing
        } else {
            context = PortForwardingConnection(host: host, route: hosts.route(for: host))
            connections[host.id] = context
        }
        generations[id] = UUID()
        presentations[id] = context
        states[id] = .preparing
        if context.connected {
            startRule(rule, in: context)
        } else if context.task == nil && context.authenticationPrompt == nil {
            open(context)
        } else {
            states[id] =
                context.authenticationPrompt != nil || context.connection.keyboardAuthentication.current != nil
                ? .awaitingAuthentication : context.connection.pendingHostKey != nil ? .awaitingTrust : .connecting
        }
    }

    public func retry(_ id: PortForwardingRule.ID) { start(id) }

    public func stop(_ id: PortForwardingRule.ID) {
        generations[id] = nil
        states[id] = .stopped
        guard let context = presentations.removeValue(forKey: id) else { return }
        let session = context.session
        let previous = ruleTasks[id]
        ruleTasks[id] = Task {
            if let previous { await previous.value }
            if let session { await session.stop(id) }
        }
        if activeIDs(context).isEmpty { retire(context) }
    }

    public func stop(_ ids: [PortForwardingRule.ID]) { ids.forEach(stop) }
    public func stopAll() { stop(Array(presentations.keys)) }
    public func remove(_ ids: [PortForwardingRule.ID]) {
        stop(ids)
        for id in ids { states[id] = nil }
    }

    /// Connection edits include jump hosts. Authentication's own explicit save may continue its opening.
    public func hostConfigurationChanged(_ hostID: Host.ID) {
        for context in Array(connections.values) where context.route.contains(where: { $0.id == hostID }) {
            guard context !== savingAuthentication else { continue }
            stop(activeIDs(context))
        }
    }

    public func reconcileConfiguration() {
        for context in Array(connections.values) {
            guard
                context.route.allSatisfy({ old in
                    hosts.host(old.id).map { old.hasSameConnectionRoute(as: $0) } == true
                })
            else {
                stop(activeIDs(context))
                continue
            }
        }
        remove(presentations.keys.filter { hosts.portForwarding($0) == nil })
    }

    public func submitAuthentication(
        for id: PortForwardingRule.ID, promptID: UUID,
        identityID: UUID?, username: String, password: String?, passphrase: String?, keyID: UUID?, save: Bool
    ) {
        guard generations[id] != nil, let context = presentations[id],
            let prompt = context.authenticationPrompt, prompt.id == promptID,
            var host = hosts.host(prompt.host.id)
        else { return }
        let identity = identityID.flatMap(hosts.identity)
        let name = (identity?.username ?? username).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if prompt.requiresPassphrase, var staged = context.submissions[host.id] {
            guard let passphrase, !passphrase.isEmpty else { return }
            staged.passphrase = passphrase
            context.submissions[host.id] = staged
        } else {
            let chosenKey = identity?.keyID ?? keyID
            if save {
                savingAuthentication = context
                defer { savingAuthentication = nil }
                do {
                    let saved = identity ?? Identity(name: name, username: name, keyID: chosenKey)
                    try hosts.upsert(saved, passwordUpdate: password.map(IdentityPasswordUpdate.replace) ?? .keep)
                    host.identityID = saved.id
                    guard hosts.saveHost(host) else {
                        throw TermindSSHError.library(hosts.storageError ?? String(localized: "Unable to Save"))
                    }
                    context.route = hosts.route(for: hosts.host(context.hostID) ?? host)
                } catch {
                    var failed = prompt
                    failed.failureMessage = error.localizedDescription
                    context.setPrompt(failed)
                    return
                }
            }
            context.submissions[host.id] = SSHAuthenticationSubmission(
                username: name, password: password, passphrase: passphrase, keyID: chosenKey, identityID: identity?.id)
        }
        context.setPrompt(nil)
        context.journey.resume()
        open(context)
    }

    public func acceptHostKey(for id: UUID, requestID: UUID, observation: SSHHostKeyObservation, remember: Bool) {
        guard generations[id] != nil, let context = presentations[id],
            context.hostKeyRequestID == requestID,
            context.connection.pendingHostKey?.observation == observation
        else { return }
        if remember {
            context.connection.trustHostKey(observation, using: hosts)
        } else {
            _ = context.connection.useTemporaryHostKey(observation)
        }
        update(context, state: .connecting)
    }

    private func activeIDs(_ context: PortForwardingConnection) -> [UUID] {
        generations.keys.filter { presentations[$0] === context }
    }

    private func isCurrent(_ context: PortForwardingConnection, attempt: UUID) -> Bool {
        connections[context.hostID] === context && context.attemptID == attempt && !activeIDs(context).isEmpty
    }

    private func update(_ context: PortForwardingConnection, state: PortForwardingRuntimeState) {
        for id in activeIDs(context) { states[id] = state }
    }

    private func open(_ context: PortForwardingConnection) {
        guard let host = hosts.host(context.hostID), !activeIDs(context).isEmpty else { return }
        let attempt = UUID()
        context.attemptID = attempt
        context.journey.begin(
            host: host, route: hosts.route(for: host), purpose: .portForwarding,
            username: context.submissions[host.id]?.username ?? hosts.identity(for: host)?.username)
        update(context, state: .preparing)
        let session = makeSession(
            { [weak self, weak context] id, count in
                Task { @MainActor in
                    guard let self, let context, self.isCurrent(context, attempt: attempt),
                        self.generations[id] != nil, self.presentations[id] === context,
                        case .running = self.states[id]
                    else { return }
                    self.states[id] = .running(activeConnections: count)
                }
            },
            { [weak self, weak context] message in
                Task { @MainActor in
                    guard let self, let context, self.isCurrent(context, attempt: attempt) else { return }
                    self.fail(context, message: message)
                }
            })
        context.session = session
        context.task = Task { [weak self, weak context] in
            guard let self, let context else { return }
            do {
                let preparation = try hosts.prepareSSHConnection(
                    for: host, submissions: context.submissions,
                    temporaryHostKeys: context.connection.temporaryHostKeys)
                let configuration = try await preparation.resolve(trustPolicy: .allowChallenge)
                guard isCurrent(context, attempt: attempt) else { throw CancellationError() }
                update(context, state: .connecting)
                try await session.connect(
                    SSHConnectionRequest(
                        configuration: configuration,
                        authorizeHostKey: { [weak self, weak context] challenge in
                            guard let self, let context else { throw CancellationError() }
                            return await self.authorize(challenge, in: context, attempt: attempt)
                        },
                        keyboardInteractive: { [weak self, weak context] challenge in
                            guard let self, let context else { throw CancellationError() }
                            return try await self.answer(challenge, in: context, attempt: attempt)
                        }),
                    progress: { [weak self, weak context] event in
                        Task { @MainActor in
                            guard let self, let context, self.isCurrent(context, attempt: attempt) else { return }
                            context.journey.receive(event)
                        }
                    })
                try Task.checkCancellation()
                guard isCurrent(context, attempt: attempt) else { throw CancellationError() }
                context.task = nil
                context.connected = true
                context.submissions.removeAll()
                context.connection.temporaryHostKeys.removeAll()
                for id in activeIDs(context) {
                    if let rule = hosts.portForwarding(id) { startRule(rule, in: context) }
                }
            } catch {
                await session.disconnect()
                guard isCurrent(context, attempt: attempt) else { return }
                context.task = nil
                context.attemptID = nil
                context.session = nil
                if let ssh = error as? TermindSSHError,
                    ssh.isLocalAuthenticationRequirement || ssh.shouldRequestAuthentication
                {
                    requestAuthentication(context, error: ssh)
                } else {
                    fail(context, message: error.localizedDescription)
                }
            }
        }
    }

    private func authorize(
        _ challenge: SSHHostKeyChallenge, in context: PortForwardingConnection, attempt: UUID
    ) async -> SSHHostKeyDecision {
        guard isCurrent(context, attempt: attempt), !Task.isCancelled else { return .reject }
        let requestID = UUID()
        context.hostKeyRequestID = requestID
        defer {
            if context.hostKeyRequestID == requestID { context.hostKeyRequestID = nil }
        }
        update(context, state: .awaitingTrust)
        let decision = await context.connection.authorizeHostKey(challenge, using: hosts)
        guard isCurrent(context, attempt: attempt), !Task.isCancelled else { return .reject }
        update(context, state: .connecting)
        return decision
    }

    private func answer(
        _ challenge: SSHKeyboardInteractiveChallenge, in context: PortForwardingConnection, attempt: UUID
    ) async throws -> [String] {
        guard isCurrent(context, attempt: attempt) else { throw CancellationError() }
        try Task.checkCancellation()
        update(context, state: .awaitingAuthentication)
        let answers = try await context.connection.answerKeyboardInteractive(challenge)
        guard isCurrent(context, attempt: attempt) else { throw CancellationError() }
        update(context, state: .connecting)
        return answers
    }

    private func requestAuthentication(_ context: PortForwardingConnection, error: TermindSSHError) {
        guard let host = hosts.host(error.routeHostID ?? context.hostID) else {
            fail(context, message: error.localizedDescription)
            return
        }
        let staged = context.submissions[host.id]
        let identity = staged?.identityID.flatMap(hosts.identity) ?? hosts.identity(for: host)
        let keyID = staged?.keyID ?? identity?.keyID
        let passphrase = keyID.flatMap(hosts.key)?.requiresPassphraseEntry == true && staged?.passphrase == nil
        context.setPrompt(
            SSHAuthenticationPrompt(
                host: host, selectedIdentityID: identity?.id, username: staged?.username ?? identity?.username ?? "",
                selectedKeyID: keyID, failureMessage: error.localizedDescription, requiresPassphrase: passphrase,
                mode: error.isServerAuthenticationChallenge ? .serverChallenge : .localIdentity))
        if error.isServerAuthenticationChallenge {
            context.journey.waitForAuthentication(at: host.id, failure: error.localizedDescription)
        } else if passphrase {
            context.journey.waitForLocalPassphrase(at: host.id, failure: error.localizedDescription)
        } else {
            context.journey.waitForLocalIdentity(at: host.id, failure: error.localizedDescription)
        }
        update(context, state: .awaitingAuthentication)
    }

    private func startRule(_ rule: PortForwardingRule, in context: PortForwardingConnection) {
        guard let token = generations[rule.id], let session = context.session else { return }
        states[rule.id] = .starting
        let previous = ruleTasks[rule.id]
        ruleTasks[rule.id] = Task { [weak self] in
            if let previous { await previous.value }
            guard let self, generations[rule.id] == token else { return }
            do {
                try await session.start(rule)
                guard generations[rule.id] == token else { return }
                states[rule.id] = .running(activeConnections: 0)
                context.journey.succeed()
            } catch {
                guard generations[rule.id] == token else { return }
                generations[rule.id] = nil
                states[rule.id] = .failed(error.localizedDescription)
                if activeIDs(context).isEmpty {
                    retire(context)
                    context.journey.fail(error.localizedDescription)
                }
            }
        }
    }

    private func fail(_ context: PortForwardingConnection, message: String) {
        for id in activeIDs(context) {
            generations[id] = nil
            states[id] = .failed(message)
        }
        retire(context)
        context.journey.fail(message)
    }

    private func retire(_ context: PortForwardingConnection) {
        context.attemptID = nil
        context.task?.cancel()
        context.task = nil
        context.connected = false
        context.setPrompt(nil)
        context.hostKeyRequestID = nil
        context.submissions.removeAll()
        context.connection.disconnect()
        let session = context.session
        context.session = nil
        if let session { Task { await session.disconnect() } }
        if connections[context.hostID] === context { connections[context.hostID] = nil }
    }
}
