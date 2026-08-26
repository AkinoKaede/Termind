import Foundation

nonisolated enum PortForwardingRuntimeState: Hashable, Sendable {
    case stopped
    case preparing
    case awaitingTrust
    case awaitingAuthentication
    case connecting
    case starting
    case running(activeConnections: Int)
    case reconnecting(attempt: Int, nextRetry: Date, message: String)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .preparing, .awaitingTrust, .awaitingAuthentication, .connecting,
            .starting, .running, .reconnecting: true
        case .stopped, .failed: false
        }
    }

    var label: String {
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

/// Process-local intent and live resources. No state in this type is persisted,
/// which guarantees that launching Termind never silently exposes a saved port.
@Observable
final class PortForwardingController {
    private let hosts: HostLibraryModel
    private(set) var states: [PortForwardingRule.ID: PortForwardingRuntimeState] = [:]
    private var desired: Set<PortForwardingRule.ID> = []
    private var sessions: [Host.ID: SSHForwardingSession] = [:]
    private var connectionTasks: [Host.ID: Task<Void, any Error>] = [:]
    private var reconnectTasks: [Host.ID: Task<Void, Never>] = [:]
    private var reconnectAttempts: [Host.ID: Int] = [:]
    private var connectedAt: [Host.ID: Date] = [:]

    init(hosts: HostLibraryModel) { self.hosts = hosts }

    func state(for id: PortForwardingRule.ID) -> PortForwardingRuntimeState {
        states[id] ?? .stopped
    }

    func isEnabled(_ id: PortForwardingRule.ID) -> Bool { desired.contains(id) }

    func start(_ id: PortForwardingRule.ID) {
        guard let rule = hosts.portForwarding(id), !desired.contains(id) else { return }
        desired.insert(id)
        states[id] = .preparing
        Task { await start(rule) }
    }

    func start(_ ids: [PortForwardingRule.ID]) { ids.forEach(start) }

    func stop(_ id: PortForwardingRule.ID) {
        desired.remove(id)
        states[id] = .stopped
        guard let rule = hosts.portForwarding(id), let session = sessions[rule.hostID] else { return }
        Task {
            await session.stop(id)
            await disconnectHostIfIdle(rule.hostID)
        }
    }

    func stop(_ ids: [PortForwardingRule.ID]) { ids.forEach(stop) }

    func stopAll() {
        let all = Array(desired)
        desired.removeAll()
        for id in all { states[id] = .stopped }
        let active = sessions
        sessions.removeAll()
        connectionTasks.values.forEach { $0.cancel() }
        connectionTasks.removeAll()
        reconnectTasks.values.forEach { $0.cancel() }
        reconnectTasks.removeAll()
        reconnectAttempts.removeAll()
        connectedAt.removeAll()
        Task { for session in active.values { await session.disconnect() } }
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
                    try await created.connect(configuration)
                }
                connectionTasks[host.id] = task
                do { try await task.value }
                catch {
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
            guard desired.contains(rule.id) else { await session.stop(rule.id); return }
            states[rule.id] = .running(activeConnections: 0)
        } catch {
            if desired.contains(rule.id),
                let sshError = error as? TermindSSHError,
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
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
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
