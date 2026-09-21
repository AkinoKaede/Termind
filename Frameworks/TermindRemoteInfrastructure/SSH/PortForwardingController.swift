import Foundation
import Logging
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

public nonisolated enum PortForwardingRuntimeState: Hashable, Sendable {
    case stopped
    case preparing
    case awaitingTrust
    case awaitingAuthentication
    case connecting
    case reconnecting
    case starting
    case running(activeConnections: Int, sshConnections: Int = 1, targetSSHConnections: Int = 1)
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
        case .reconnecting: String(localized: "Reconnecting")
        case .starting: String(localized: "Starting")
        case .running(let count, let sshConnections, let targetSSHConnections):
            if targetSSHConnections > 1 {
                String(localized: "Running · SSH \(sshConnections)/\(targetSSHConnections) · \(count) TCP flows")
            } else if count == 0 {
                String(localized: "Running")
            } else if count == 1 {
                String(localized: "Running · 1 connection")
            } else {
                String(localized: "Running · \(count) connections")
            }
        case .failed(let message): message
        }
    }

    public var compactLabel: String {
        switch self {
        case .running: String(localized: "Running")
        case .failed: String(localized: "Failed")
        default: label
        }
    }
}

/// A host's manually opened transport and its shared authentication surface.
@Observable
public final class PortForwardingConnection {
    public let hostID: Host.ID
    public let connection: RemoteSessionConnectionController
    public var journey: ConnectionJourney { connection.journey }
    public private(set) var authenticationPrompt: SSHAuthenticationPrompt?
    public fileprivate(set) var poolStatus = SSHForwardingPoolStatus.single
    public fileprivate(set) var hostKeyRequestID: UUID?
    fileprivate var route: [Host]
    fileprivate var submissions: [Host.ID: SSHAuthenticationSubmission] = [:]
    fileprivate var proxySubmissions: [Host.ID: SSHProxyAuthenticationSubmission] = [:]
    fileprivate var attemptID: UUID?
    fileprivate var forwardingConnection: (any SSHForwardingConnectionProtocol)?
    fileprivate var task: Task<Void, Never>?
    fileprivate var connected = false
    fileprivate var ready = false
    fileprivate var silentAttempt = false
    fileprivate var additionalSnapshot: SSHAdditionalConnectionSnapshot?
    fileprivate var connectionCounts: [PortForwardingRule.ID: Int] = [:]
    fileprivate let maximumConnections: Int

    fileprivate init(
        host: Host, route: [Host], maximumConnections: Int, reconnect: SessionReconnectController
    ) {
        hostID = host.id
        self.route = route
        self.maximumConnections = maximumConnections
        connection = RemoteSessionConnectionController(reconnect: reconnect)
    }

    fileprivate func setPrompt(_ prompt: SSHAuthenticationPrompt?) { authenticationPrompt = prompt }
}

/// Explicit Start owns runtime intent. Established connections recover silently until Stop or a terminal failure.
@Observable
public final class PortForwardingController {
    public nonisolated enum PoolPolicy: Sendable {
        case singleConnection
        case hostConfigured

        fileprivate func maximumConnections(for host: Host) -> Int {
            switch self {
            case .singleConnection: 1
            case .hostConfigured:
                Host.normalizedPortForwardingMaxConnections(host.portForwardingMaxConnections)
            }
        }
    }

    public typealias ConnectionFactory =
        @MainActor (
            @escaping SSHForwardingConnection.ConnectionHandler, @escaping SSHForwardingConnection.FailureHandler
        ) -> any SSHForwardingConnectionProtocol

    private let hosts: HostLibraryModel
    private let makeConnection:
        @MainActor (
            Int, @escaping SSHForwardingConnection.ConnectionHandler,
            @escaping SSHForwardingConnection.FailureHandler
        ) -> any SSHForwardingConnectionProtocol
    private let poolPolicy: PoolPolicy
    private let logger: Logger
    private let makeReconnectController: @MainActor () -> SessionReconnectController
    public private(set) var states: [PortForwardingRule.ID: PortForwardingRuntimeState] = [:]
    private var connections: [Host.ID: PortForwardingConnection] = [:]
    private var presentations: [PortForwardingRule.ID: PortForwardingConnection] = [:]
    private var generations: [PortForwardingRule.ID: UUID] = [:]
    private var ruleTasks: [PortForwardingRule.ID: Task<Void, Never>] = [:]
    private var cleanupTasks: [Host.ID: Task<Void, Never>] = [:]
    private var savingAuthentication: PortForwardingConnection?

    public init(
        hosts: HostLibraryModel,
        poolPolicy: PoolPolicy = .singleConnection,
        logger: Logger = ApplicationLogger.disabled("termind.port-forwarding"),
        makeConnection: ConnectionFactory? = nil,
        makeReconnectController: @escaping @MainActor () -> SessionReconnectController = {
            SessionReconnectController()
        }
    ) {
        self.hosts = hosts
        self.logger = logger
        self.poolPolicy = poolPolicy
        self.makeReconnectController = makeReconnectController
        if let makeConnection {
            self.makeConnection = { _, connectionHandler, failureHandler in
                makeConnection(connectionHandler, failureHandler)
            }
        } else {
            self.makeConnection = { maximumConnections, connectionHandler, failureHandler in
                if maximumConnections > 1 {
                    SSHForwardingConnectionPool(
                        maximumConnections: maximumConnections,
                        connectionHandler: connectionHandler, failureHandler: failureHandler, logger: logger)
                } else {
                    SSHForwardingConnection(
                        connectionHandler: connectionHandler, failureHandler: failureHandler, logger: logger)
                }
            }
        }
    }

    public func state(for id: PortForwardingRule.ID) -> PortForwardingRuntimeState { states[id] ?? .stopped }
    public func connection(for id: PortForwardingRule.ID) -> PortForwardingConnection? { presentations[id] }

    public func start(_ id: PortForwardingRule.ID) {
        guard !state(for: id).isActive, let rule = hosts.portForwarding(id), rule.isValid,
            let host = hosts.host(rule.hostID), host.sshEnabled
        else { return }
        logger.info(
            "forwarding.requested",
            metadata: [
                "forwarding_kind": RemoteLogging.forwardingKind(rule.kind),
                "host_id": RemoteLogging.hostID(rule.hostID),
                "operation_id": "\(UUID().uuidString.lowercased())", "stage": "requested",
            ])
        let context: PortForwardingConnection
        if let existing = connections[host.id], !activeIDs(existing).isEmpty {
            context = existing
        } else {
            context = PortForwardingConnection(
                host: host, route: hosts.route(for: host),
                maximumConnections: poolPolicy.maximumConnections(for: host),
                reconnect: makeReconnectController())
            connections[host.id] = context
        }
        generations[id] = UUID()
        presentations[id] = context
        states[id] = .preparing
        if context.connected {
            startRule(rule, in: context)
        } else if context.connection.isRecovering {
            states[id] = .reconnecting
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
        let forwardingConnection = context.forwardingConnection
        let previous = ruleTasks[id]
        ruleTasks[id] = Task {
            if let forwardingConnection { await forwardingConnection.stop(id) }
            if let previous { await previous.value }
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
        let name = ((prompt.isProxy ? nil : identity?.username) ?? username)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if prompt.isProxy {
            let submission = SSHProxyAuthenticationSubmission(
                username: name, password: password, identityID: identity?.id)
            do {
                if save {
                    savingAuthentication = context
                    defer { savingAuthentication = nil }
                    host = try hosts.saveProxyAuthentication(
                        submission, for: host, selectedIdentity: identity,
                        suppliedPassword: password)
                    context.route = hosts.route(for: hosts.host(context.hostID) ?? host)
                }
                context.proxySubmissions[host.id] = submission
                context.setPrompt(nil)
                context.journey.resume()
                open(context)
            } catch {
                var failed = prompt
                failed.failureMessage = error.localizedDescription
                context.setPrompt(failed)
            }
            return
        }
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
        guard let host = hosts.host(context.hostID), connections[host.id] === context,
            !activeIDs(context).isEmpty, context.task == nil, !context.connected
        else { return }
        let silently = context.connection.isRecovering
        let attempt = UUID()
        context.attemptID = attempt
        context.silentAttempt = silently
        if !silently {
            context.journey.begin(
                host: host, route: hosts.route(for: host), purpose: .portForwarding,
                username: context.submissions[host.id]?.username ?? hosts.identity(for: host)?.username)
            update(context, state: .preparing)
            if let proxyHost = context.proxySubmissions.firstHostRequiringProxyPassword(in: context.route) {
                requestAuthentication(
                    context,
                    error: .proxyAuthentication(
                        hostID: proxyHost.id, serverChallenge: false,
                        message: String(localized: "The proxy password is unavailable.")))
                context.attemptID = nil
                return
            }
            if let passwordHost = context.submissions.firstHostRequiringPassword(in: context.route) {
                requestAuthentication(
                    context,
                    error: .routeHost(
                        hostID: passwordHost.id, authentication: true,
                        serverChallenge: false, hostKey: false,
                        message: TermindSSHError.missingCredential.localizedDescription
                    )
                )
                context.attemptID = nil
                return
            }
            if let passphraseHost = context.submissions.firstHostRequiringPassphrase(
                in: context.route, key: hosts.key
            ) {
                requestAuthentication(
                    context,
                    error: .routeHost(
                        hostID: passphraseHost.id, authentication: true,
                        serverChallenge: false, hostKey: false,
                        message: TermindSSHError.keyPassphraseRequired.localizedDescription
                    )
                )
                context.attemptID = nil
                return
            }
        }
        let attemptSubmissions = silently ? [:] : context.submissions.takeAuthenticationSecrets()
        let attemptProxySubmissions = silently ? [:] : context.proxySubmissions.takeProxyAuthenticationSecrets()
        let forwardingConnection = makeConnection(
            context.maximumConnections,
            { [weak self, weak context] id, generation, count in
                Task { @MainActor in
                    guard let self, let context, self.isCurrent(context, attempt: attempt),
                        self.generations[id] == generation, self.presentations[id] === context
                    else { return }
                    context.connectionCounts[id] = count
                    let poolStatus = await context.forwardingConnection?.connectionPoolStatus() ?? .single
                    context.poolStatus = poolStatus
                    let running = PortForwardingRuntimeState.running(
                        activeConnections: count, sshConnections: poolStatus.connected,
                        targetSSHConnections: poolStatus.target)
                    if case .running = self.states[id], self.states[id] != running {
                        self.states[id] = running
                    }
                }
            },
            { [weak self, weak context] message in
                Task { @MainActor in
                    guard let self, let context, self.isCurrent(context, attempt: attempt) else { return }
                    self.recover(context, message: message)
                }
            })
        context.forwardingConnection = forwardingConnection
        let cleanup = cleanupTasks[context.hostID]
        context.task = Task { [weak self, weak context] in
            guard let self, let context else { return }
            do {
                await cleanup?.value
                try Task.checkCancellation()
                let configuration: SSHConnectionConfiguration
                if silently {
                    guard let snapshot = context.additionalSnapshot else { throw TermindSSHError.missingCredential }
                    configuration = try hosts.additionalConnectionRequest(from: snapshot).configuration
                } else {
                    let preparation = try hosts.prepareSSHConnection(
                        for: host, submissions: attemptSubmissions,
                        proxySubmissions: attemptProxySubmissions,
                        temporaryHostKeys: context.connection.temporaryHostKeys)
                    configuration = try await preparation.resolve(trustPolicy: .allowChallenge)
                }
                guard isCurrent(context, attempt: attempt) else { throw CancellationError() }
                if silently {
                    try await forwardingConnection.connect(
                        SSHConnectionRequest(configuration: configuration, interactionPolicy: .forbidden)
                            .enforcingInteractionPolicy(), progress: nil)
                } else {
                    update(context, state: .connecting)
                    let request = SSHConnectionRequest(
                        configuration: configuration,
                        authorizeHostKey: { [weak self, weak context] challenge in
                            guard let self, let context else { throw CancellationError() }
                            return await self.authorize(challenge, in: context, attempt: attempt)
                        },
                        keyboardInteractive: { [weak self, weak context] challenge in
                            guard let self, let context else { throw CancellationError() }
                            return try await self.answer(challenge, in: context, attempt: attempt)
                        })
                    try await forwardingConnection.connect(
                        request,
                        progress: { [weak self, weak context] event in
                            Task { @MainActor in
                                guard let self, let context, self.isCurrent(context, attempt: attempt) else { return }
                                context.journey.receive(event)
                            }
                        })
                }
                try Task.checkCancellation()
                guard isCurrent(context, attempt: attempt) else { throw CancellationError() }
                context.task = nil
                context.connected = true
                if !silently {
                    context.additionalSnapshot = hosts.additionalConnectionSnapshot(from: configuration)
                }
                if let snapshot = context.additionalSnapshot {
                    await forwardingConnection.configureAdditionalConnections { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try self.hosts.additionalConnectionRequest(from: snapshot)
                    }
                }
                context.submissions.removeAll()
                context.proxySubmissions.removeAll()
                context.connection.temporaryHostKeys.removeAll()
                for id in activeIDs(context) {
                    if let rule = hosts.portForwarding(id) { startRule(rule, in: context) }
                }
            } catch {
                await forwardingConnection.disconnect()
                guard isCurrent(context, attempt: attempt) else { return }
                context.task = nil
                context.attemptID = nil
                context.forwardingConnection = nil
                if silently {
                    if Self.requiresManualRetry(error) {
                        fail(context, message: error.localizedDescription, presentJourney: false)
                    } else {
                        recover(context, message: error.localizedDescription)
                    }
                } else if let ssh = error as? TermindSSHError,
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
        if error.isProxyAuthentication, let proxy = host.proxy {
            let staged = context.proxySubmissions.removeValue(forKey: host.id)
            let configured = (staged?.identityID ?? proxy.identityID).flatMap(hosts.identity)
            let selected: Identity?
            if let configured {
                switch hosts.passwordAvailability(for: configured) {
                case .available, .notConfigured: selected = configured
                case .missing, .failed: selected = nil
                }
            } else {
                selected = nil
            }
            context.setPrompt(
                SSHAuthenticationPrompt(
                    host: Host(
                        id: host.id, name: String(localized: "Proxy for \(host.name)"),
                        host: proxy.hostname, port: proxy.port),
                    selectedIdentityID: selected?.id,
                    username: staged?.username ?? proxy.username,
                    failureMessage: error.localizedDescription,
                    mode: error.isServerAuthenticationChallenge ? .serverChallenge : .localIdentity,
                    target: .proxy(ownerHostID: host.id)))
            context.journey.waitForProxyAuthentication(at: host.id, failure: error.localizedDescription)
            update(context, state: .awaitingAuthentication)
            return
        }
        let staged = context.submissions[host.id]
        let identity = staged?.identityID.flatMap(hosts.identity) ?? hosts.identity(for: host)
        let keyID = staged?.keyID ?? identity?.keyID
        let passphrase =
            staged?.requiresPasswordReentry != true
            && keyID.flatMap(hosts.key)?.requiresPassphraseEntry == true
            && staged?.passphrase == nil
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
        guard let token = generations[rule.id], let forwardingConnection = context.forwardingConnection,
            let attempt = context.attemptID
        else {
            return
        }
        let silently = context.silentAttempt
        context.connectionCounts[rule.id] = 0
        states[rule.id] = silently ? .reconnecting : .starting
        let previous = ruleTasks[rule.id]
        ruleTasks[rule.id] = Task { [weak self] in
            if let previous { await previous.value }
            guard let self, generations[rule.id] == token, isCurrent(context, attempt: attempt) else { return }
            do {
                try await forwardingConnection.start(rule, generation: token)
                guard generations[rule.id] == token, isCurrent(context, attempt: attempt) else {
                    await forwardingConnection.stop(rule.id)
                    return
                }
                let poolStatus = await forwardingConnection.connectionPoolStatus()
                context.poolStatus = poolStatus
                states[rule.id] = .running(
                    activeConnections: context.connectionCounts[rule.id] ?? 0,
                    sshConnections: poolStatus.connected, targetSSHConnections: poolStatus.target)
                if !context.ready {
                    context.ready = true
                    context.connection.markConnected()
                }
                if !silently { context.journey.succeed() }
            } catch {
                guard generations[rule.id] == token, isCurrent(context, attempt: attempt) else { return }
                // Transport cleanup can finish a pending remote listen before its failure callback arrives.
                if error is CancellationError
                    || (error as? TermindSSHError).map({
                        if case .disconnected = $0 { return true }
                        return false
                    }) == true
                {
                    recover(context, message: error.localizedDescription)
                    return
                }
                generations[rule.id] = nil
                states[rule.id] = .failed(error.localizedDescription)
                if activeIDs(context).isEmpty {
                    retire(context)
                    if !silently { context.journey.fail(error.localizedDescription) }
                }
            }
        }
    }

    private static func requiresManualRetry(_ error: any Error) -> Bool {
        if error is SSHInteractionRequired || error is CancellationError { return true }
        guard let ssh = error as? TermindSSHError else { return false }
        if ssh.isLocalAuthenticationRequirement || ssh.shouldRequestAuthentication || ssh.shouldRequestHostKey {
            return true
        }
        switch ssh {
        case .untrustedHost, .mismatchedHostKey, .hostKeyChanged: return true
        default: return false
        }
    }

    private func recover(_ context: PortForwardingConnection, message: String) {
        guard context.connection.hasConnectedOnce, context.additionalSnapshot != nil else {
            fail(context, message: message)
            return
        }
        closeTransport(context)
        context.journey.hide()
        update(context, state: .reconnecting)
        context.connection.scheduleRecovery(after: message) { [weak self, weak context] in
            guard let self, let context, self.connections[context.hostID] === context,
                context.connection.isRecovering
            else { return }
            self.open(context)
        }
    }

    private func fail(_ context: PortForwardingConnection, message: String, presentJourney: Bool = true) {
        for id in activeIDs(context) {
            generations[id] = nil
            states[id] = .failed(message)
        }
        retire(context)
        if presentJourney { context.journey.fail(message) }
    }

    private func closeTransport(_ context: PortForwardingConnection) {
        context.attemptID = nil
        let opening = context.task
        context.task?.cancel()
        context.task = nil
        context.connected = false
        context.ready = false
        context.connectionCounts.removeAll()
        context.poolStatus = SSHForwardingPoolStatus(connected: 0, target: context.maximumConnections)
        let forwardingConnection = context.forwardingConnection
        context.forwardingConnection = nil
        let previous = cleanupTasks[context.hostID]
        cleanupTasks[context.hostID] = Task {
            await previous?.value
            await opening?.value
            await forwardingConnection?.disconnect()
        }
    }

    private func retire(_ context: PortForwardingConnection) {
        closeTransport(context)
        context.setPrompt(nil)
        context.hostKeyRequestID = nil
        context.submissions.removeAll()
        context.proxySubmissions.removeAll()
        context.additionalSnapshot = nil
        context.connection.disconnect()
        if connections[context.hostID] === context { connections[context.hostID] = nil }
    }
}
