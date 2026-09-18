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
    case reconnecting(attempt: Int, nextRetry: Date, message: String)
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .preparing, .awaitingTrust, .awaitingAuthentication, .connecting,
            .starting, .running, .reconnecting:
            true
        case .stopped, .failed: false
        }
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
        case .reconnecting(let attempt, _, _): String(localized: "Reconnecting · attempt \(attempt)")
        case .failed(let message): message
        }
    }
}

/// Keeps device-local enabled intent separate from process-local SSH resources.
/// Enabled rule IDs are not part of Vault or Settings sync.
@Observable
public final class PortForwardingController {
    private let hosts: HostLibraryModel
    private let keyboardInteractive: SSHKeyboardInteractiveHandler?
    private let defaults: UserDefaults?
    private let enabledDefaultsKey: String
    public private(set) var states: [PortForwardingRule.ID: PortForwardingRuntimeState] = [:]
    private var enabled: Set<PortForwardingRule.ID>
    /// Enabled IDs created in this process before their rules have been saved.
    /// Unlike stale IDs restored from defaults, these survive reconciliation until
    /// their editor explicitly discards them or a save makes them runnable.
    private var pending: Set<PortForwardingRule.ID> = []
    private var desired: Set<PortForwardingRule.ID> = []
    private var sessions: [Host.ID: SSHForwardingSession] = [:]
    private var connectionTasks: [Host.ID: Task<Void, any Error>] = [:]
    private var reconnectTasks: [Host.ID: Task<Void, Never>] = [:]
    private var reconnectAttempts: [Host.ID: Int] = [:]
    private var connectedAt: [Host.ID: Date] = [:]
    private var ruleHostIDs: [PortForwardingRule.ID: Host.ID]
    private var stoppingTasks: [PortForwardingRule.ID: Task<Void, Never>] = [:]
    private var stoppingGenerations: [PortForwardingRule.ID: UUID] = [:]

    public init(
        hosts: HostLibraryModel, defaults: UserDefaults? = nil,
        enabledDefaultsKey: String = SettingsKey.portForwardingEnabledRuleIDs,
        keyboardInteractive: SSHKeyboardInteractiveHandler? = nil
    ) {
        self.hosts = hosts
        self.keyboardInteractive = keyboardInteractive
        self.defaults = defaults
        self.enabledDefaultsKey = enabledDefaultsKey
        enabled = Set(
            defaults?.stringArray(forKey: enabledDefaultsKey)?.compactMap(UUID.init(uuidString:)) ?? [])
        ruleHostIDs = Dictionary(uniqueKeysWithValues: hosts.portForwardings.map { ($0.id, $0.hostID) })
    }

    public func state(for id: PortForwardingRule.ID) -> PortForwardingRuntimeState {
        states[id] ?? .stopped
    }

    public func isEnabled(_ id: PortForwardingRule.ID) -> Bool { enabled.contains(id) }

    public func setEnabled(_ value: Bool, for id: PortForwardingRule.ID) {
        if value {
            enabled.insert(id)
            if let rule = hosts.portForwarding(id), rule.isValid, hosts.host(rule.hostID) != nil {
                pending.remove(id)
            } else {
                pending.insert(id)
            }
            persistEnabled()
            if !pending.contains(id) { activate(id) }
        } else {
            enabled.remove(id)
            pending.remove(id)
            persistEnabled()
            suspend(id)
        }
    }

    public func setEnabled(_ value: Bool, for ids: [PortForwardingRule.ID]) {
        for id in ids { setEnabled(value, for: id) }
    }

    /// Restores all, or a changed subset, after launch, foregrounding, or a saved configuration replacement.
    public func resumeEnabled(_ ids: [PortForwardingRule.ID]? = nil) {
        var valid: Set<PortForwardingRule.ID> = []
        for id in enabled {
            guard let rule = hosts.portForwarding(id), rule.isValid, hosts.host(rule.hostID) != nil else { continue }
            ruleHostIDs[rule.id] = rule.hostID
            valid.insert(id)
        }
        pending.subtract(valid)
        let reconciled = valid.union(pending.intersection(enabled))
        if reconciled != enabled {
            enabled = reconciled
            persistEnabled()
        }
        let targets = ids.map { valid.intersection($0) } ?? valid
        targets.forEach(activate)
    }

    /// Stops live resources while preserving the device-local enabled intent.
    public func suspend(_ id: PortForwardingRule.ID) {
        let hostID = hosts.portForwarding(id)?.hostID ?? ruleHostIDs[id]
        let session = hostID.flatMap { sessions[$0] }
        desired.remove(id)
        states[id] = .stopped
        let previous = stoppingTasks[id]
        let generation = UUID()
        stoppingGenerations[id] = generation
        let task = Task {
            if let previous { await previous.value }
            if let session { await session.stop(id) }
        }
        stoppingTasks[id] = task
        Task { [weak self] in
            await task.value
            guard let self, self.stoppingGenerations[id] == generation else { return }
            self.stoppingTasks[id] = nil
            self.stoppingGenerations[id] = nil
            if let hostID { await self.disconnectHostIfIdle(hostID) }
        }
    }

    public func suspend(_ ids: [PortForwardingRule.ID]) { ids.forEach(suspend) }

    /// Forgets enabled intent only for rules that were enabled before their first save.
    public func discardPending(_ ids: [PortForwardingRule.ID]) {
        let discarded = pending.intersection(ids)
        guard !discarded.isEmpty else { return }
        pending.subtract(discarded)
        enabled.subtract(discarded)
        for id in discarded { states[id] = nil }
        persistEnabled()
    }

    public func remove(_ ids: [PortForwardingRule.ID]) {
        for id in ids {
            enabled.remove(id)
            pending.remove(id)
            suspend(id)
            ruleHostIDs[id] = nil
        }
        persistEnabled()
    }

    public func suspendAll() {
        let all = Array(enabled.union(desired))
        desired.removeAll()
        for id in all { states[id] = .stopped }
        let active = sessions
        sessions.removeAll()
        for task in connectionTasks.values { task.cancel() }
        connectionTasks.removeAll()
        for task in reconnectTasks.values { task.cancel() }
        reconnectTasks.removeAll()
        reconnectAttempts.removeAll()
        connectedAt.removeAll()
        for task in stoppingTasks.values { task.cancel() }
        stoppingTasks.removeAll()
        stoppingGenerations.removeAll()
        Task { for session in active.values { await session.disconnect() } }
    }

    private func activate(_ id: PortForwardingRule.ID) {
        guard enabled.contains(id), !desired.contains(id) else { return }
        if let rule = hosts.portForwarding(id) { ruleHostIDs[id] = rule.hostID }
        desired.insert(id)
        states[id] = .preparing
        let stopping = stoppingTasks[id]
        Task { [weak self] in
            if let stopping { await stopping.value }
            guard let self, self.desired.contains(id), self.enabled.contains(id),
                let rule = self.hosts.portForwarding(id)
            else { return }
            await self.start(rule)
        }
    }

    private func persistEnabled() {
        defaults?.set(enabled.map(\.uuidString).sorted(), forKey: enabledDefaultsKey)
    }

    private func start(_ rule: PortForwardingRule) async {
        do {
            guard rule.isValid else {
                throw TermindSSHError.route(String(localized: "The forwarding rule is incomplete."))
            }
            guard let host = hosts.host(rule.hostID) else {
                throw TermindSSHError.route(String(localized: "The forwarding host is unavailable."))
            }
            let session: SSHForwardingSession
            if let existing = sessions[host.id] {
                session = existing
            } else {
                let created = makeSession(for: host.id)
                sessions[host.id] = created
                session = created
                states[rule.id] = .connecting
                let task = Task {
                    let configuration = try hosts.sshConnectionConfiguration(for: host)
                    try await created.connect(
                        SSHConnectionRequest(configuration: configuration, keyboardInteractive: keyboardInteractive))
                }
                connectionTasks[host.id] = task
                do { try await task.value } catch {
                    sessions[host.id] = nil
                    connectionTasks[host.id] = nil
                    throw error
                }
                connectionTasks[host.id] = nil
                connectedAt[host.id] = Date()
            }
            if let task = connectionTasks[host.id] { try await task.value }
            guard desired.contains(rule.id) else { return }
            states[rule.id] = .starting
            try await session.start(rule)
            guard desired.contains(rule.id) else {
                await session.stop(rule.id)
                return
            }
            states[rule.id] = .running(activeConnections: 0)
        } catch {
            guard desired.contains(rule.id) else {
                states[rule.id] = .stopped
                await disconnectHostIfIdle(rule.hostID)
                return
            }
            if let sshError = error as? TermindSSHError,
                sshError.isRetryableForwardingFailure
            {
                if let session = sessions.removeValue(forKey: rule.hostID) {
                    await session.disconnect()
                }
                if reconnectTasks[rule.hostID] == nil {
                    scheduleReconnect(
                        rule.hostID, attempt: 1, message: error.localizedDescription
                    )
                }
            } else {
                desired.remove(rule.id)
                states[rule.id] = .failed(error.localizedDescription)
                await disconnectHostIfIdle(rule.hostID)
            }
        }
    }

    private func disconnectHostIfIdle(_ hostID: Host.ID) async {
        let hasActiveRule = desired.contains { hosts.portForwarding($0)?.hostID == hostID }
        guard !hasActiveRule else { return }
        let session = sessions.removeValue(forKey: hostID)
        connectionTasks[hostID]?.cancel()
        connectionTasks[hostID] = nil
        reconnectTasks[hostID]?.cancel()
        reconnectTasks[hostID] = nil
        reconnectAttempts[hostID] = nil
        connectedAt[hostID] = nil
        if let session { await session.disconnect() }
    }

    private func makeSession(for hostID: Host.ID) -> SSHForwardingSession {
        SSHForwardingSession(
            connectionHandler: { [weak self] id, count in
                Task { @MainActor in
                    guard let self, self.desired.contains(id) else { return }
                    self.states[id] = .running(activeConnections: count)
                }
            },
            failureHandler: { [weak self] message in
                Task { @MainActor in self?.handleConnectionFailure(hostID, message: message) }
            }
        )
    }

    private func handleConnectionFailure(_ hostID: Host.ID, message: String) {
        guard reconnectTasks[hostID] == nil else { return }
        let ids = desiredRuleIDs(for: hostID)
        guard !ids.isEmpty else { return }
        sessions[hostID] = nil
        connectionTasks[hostID]?.cancel()
        connectionTasks[hostID] = nil
        let wasStable = connectedAt[hostID].map { Date().timeIntervalSince($0) >= 60 } == true
        let attempt = wasStable ? 1 : (reconnectAttempts[hostID] ?? 0) + 1
        scheduleReconnect(hostID, attempt: attempt, message: message)
    }

    private func scheduleReconnect(_ hostID: Host.ID, attempt: Int, message: String) {
        let delays: [TimeInterval] = [1, 2, 5, 10, 30]
        let delay = delays[min(attempt - 1, delays.count - 1)]
        let nextRetry = Date().addingTimeInterval(delay)
        reconnectAttempts[hostID] = attempt
        for id in desiredRuleIDs(for: hostID) {
            states[id] = .reconnecting(attempt: attempt, nextRetry: nextRetry, message: message)
        }
        reconnectTasks[hostID] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            await self.reconnect(hostID, attempt: attempt)
        }
    }

    private func reconnect(_ hostID: Host.ID, attempt: Int) async {
        reconnectTasks[hostID] = nil
        let ids = desiredRuleIDs(for: hostID)
        guard !ids.isEmpty, let host = hosts.host(hostID) else { return }
        let session = makeSession(for: hostID)
        do {
            let configuration = try hosts.sshConnectionConfiguration(for: host)
            try await session.connect(configuration)
            guard !desiredRuleIDs(for: hostID).isEmpty else {
                await session.disconnect()
                return
            }
            sessions[hostID] = session
            connectedAt[hostID] = Date()
            for id in desiredRuleIDs(for: hostID) {
                guard let rule = hosts.portForwarding(id) else { continue }
                states[id] = .starting
                try await session.start(rule)
                states[id] = .running(activeConnections: 0)
            }
        } catch {
            sessions[hostID] = nil
            await session.disconnect()
            if let sshError = error as? TermindSSHError,
                !sshError.isRetryableForwardingFailure
            {
                for id in desiredRuleIDs(for: hostID) {
                    desired.remove(id)
                    states[id] = .failed(error.localizedDescription)
                }
                reconnectAttempts[hostID] = nil
            } else {
                scheduleReconnect(
                    hostID, attempt: attempt + 1, message: error.localizedDescription
                )
            }
        }
    }

    private func desiredRuleIDs(for hostID: Host.ID) -> [PortForwardingRule.ID] {
        desired.filter { hosts.portForwarding($0)?.hostID == hostID }
    }
}
