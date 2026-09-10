import Foundation

nonisolated enum ConnectionPurpose: String, Hashable, Sendable {
    case sshSession
    case sftpSession
    case serialSession
    case metrics
}

nonisolated struct ConnectionEndpoint: Identifiable, Hashable, Sendable {
    nonisolated enum Role: Hashable, Sendable {
        case local
        case jump
        case destination
    }

    nonisolated enum ID: Hashable, Sendable {
        case local
        case host(Host.ID)
        case serial(String)
    }

    var id: ID
    var hostID: Host.ID?
    var name: String
    var address: String
    var role: Role
}

nonisolated enum SSHRouteEvent: Hashable, Sendable {
    case connecting(Host.ID)
    case authenticating(Host.ID)
    case authenticated(Host.ID)
    case connected(Host.ID)
    case initializing(Host.ID, String)
}

typealias SSHRouteProgressHandler = @Sendable (SSHRouteEvent) -> Void

nonisolated struct SSHAuthenticationSubmission: Hashable, Sendable {
    var username: String
    var password: String?
    var passphrase: String?
    var keyID: SSHKeyRef.ID?
    var identityID: Identity.ID? = nil
}

/// UI-facing state for one connection attempt. The transport emits facts; this model
/// turns them into a monotonic route so reconnect probes cannot visually move
/// a completed path backwards.
@Observable
final class ConnectionJourney {
    enum Mode: Equatable {
        case connection
        case reconnection
    }

    enum Phase: Equatable {
        case hidden
        case connecting
        case waiting
        case succeeded
        case failed(String)
    }

    enum CheckpointKind: Equatable {
        case authentication
        case hostKey
    }

    enum LocalRequirement: Equatable {
        case identity
        case passphrase
    }

    struct Checkpoint: Equatable {
        var endpointIndex: Int
        var kind: CheckpointKind
    }

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        var date = Date()
        var endpoint: String
        var message: String
    }

    private(set) var purpose: ConnectionPurpose = .sshSession
    private(set) var mode: Mode = .connection
    private(set) var endpoints: [ConnectionEndpoint] = []
    private(set) var phase: Phase = .hidden
    private(set) var activeEndpointIndex = 0
    private(set) var completedEndpointIndex = 0
    private(set) var checkpoint: Checkpoint?
    private(set) var completedCheckpoints: [Int: CheckpointKind] = [:]
    private(set) var localRequirement: LocalRequirement?
    private(set) var logs: [LogEntry] = []
    var showsLogs = false

    private var completionTask: Task<Void, Never>?

    var isPresented: Bool { phase != .hidden }
    var destination: ConnectionEndpoint? { endpoints.last }
    var waitsForLocalIdentity: Bool { localRequirement == .identity }
    var waitsForLocalPassphrase: Bool { localRequirement == .passphrase }

    func begin(
        host: Host, route: [Host], purpose: ConnectionPurpose,
        username: String?, mode: Mode = .connection
    ) {
        completionTask?.cancel()
        let nextEndpoints =
            [
                ConnectionEndpoint(
                    id: .local, hostID: nil,
                    name: String(localized: "This Mac"), address: "localhost", role: .local
                )
            ]
            + route.enumerated().map { index, node in
                ConnectionEndpoint(
                    id: .host(node.id), hostID: node.id, name: node.name,
                    address: index == route.count - 1 && username?.isEmpty == false
                        ? "\(username!)@\(node.displayAddress)" : node.displayAddress,
                    role: index == route.count - 1 ? .destination : .jump
                )
            }
        let continuesJourney =
            phase == .connecting && endpoints == nextEndpoints
            && !completedCheckpoints.isEmpty
        let retainedCompletedEndpoint = continuesJourney ? completedEndpointIndex : 0
        let retainedCheckpoints = continuesJourney ? completedCheckpoints : [:]
        let retainedLogs = continuesJourney ? logs : []
        let retainedLogVisibility = continuesJourney && showsLogs

        self.purpose = purpose
        self.mode = mode
        endpoints = nextEndpoints
        phase = .connecting
        activeEndpointIndex = retainedCompletedEndpoint
        completedEndpointIndex = retainedCompletedEndpoint
        checkpoint = nil
        completedCheckpoints = retainedCheckpoints
        localRequirement = nil
        logs = retainedLogs
        showsLogs = retainedLogVisibility
        let action = mode == .reconnection ? "Reconnecting " : "Starting "
        log(
            endpoint: endpoints.first?.name ?? String(localized: "This Mac"),
            message: action + purpose.logName + " connection to " + host.name
        )
        if let username, !username.isEmpty {
            log(endpoint: host.name, message: "Using login " + username)
        }
    }

    func beginSerial(name: String, address: String, mode: Mode = .connection) {
        completionTask?.cancel()
        purpose = .serialSession
        self.mode = mode
        endpoints = [
            ConnectionEndpoint(
                id: .local, hostID: nil,
                name: String(localized: "This Mac"), address: "localhost", role: .local
            ),
            ConnectionEndpoint(
                id: .serial(address), hostID: nil,
                name: name, address: address, role: .destination
            ),
        ]
        phase = .connecting
        activeEndpointIndex = 1
        completedEndpointIndex = 0
        checkpoint = nil
        completedCheckpoints = [:]
        localRequirement = nil
        logs = []
        showsLogs = false
        log(
            endpoint: endpoints[0].name,
            message: (mode == .reconnection ? "Reconnecting " : "Starting ")
                + "serial connection to " + name
        )
        log(endpoint: name, message: "Opening " + address)
    }

    func receive(_ event: SSHRouteEvent) {
        let hostID: Host.ID
        let message: String
        switch event {
        case .connecting(let id):
            hostID = id
            message = String(localized: "Opening SSH transport")
        case .authenticating(let id):
            hostID = id
            message = String(localized: "Authenticating")
        case .authenticated(let id):
            hostID = id
            message = String(localized: "Authentication accepted")
        case .connected(let id):
            hostID = id
            message = String(localized: "Host connected")
        case .initializing(let id, let detail):
            hostID = id
            message = detail
        }
        guard let index = endpoints.firstIndex(where: { $0.hostID == hostID }) else { return }

        switch event {
        case .connecting, .authenticating, .initializing:
            if index > completedEndpointIndex { activeEndpointIndex = index }
        case .authenticated:
            checkpoint = nil
            activeEndpointIndex = max(activeEndpointIndex, index)
        case .connected:
            checkpoint = nil
            completedEndpointIndex = max(completedEndpointIndex, index)
            activeEndpointIndex = max(activeEndpointIndex, index)
        }
        log(endpoint: endpoints[index].name, message: message)
    }

    func waitForAuthentication(at hostID: Host.ID, failure: String? = nil) {
        wait(at: hostID, kind: .authentication, message: failure ?? String(localized: "Waiting for authentication"))
    }

    /// Pauses before transport authentication because Termind has no usable local
    /// Identity. This is not a server challenge, so the untouched route stays
    /// gray and no midpoint checkpoint is introduced.
    func waitForLocalIdentity(at hostID: Host.ID, failure: String? = nil) {
        guard let index = endpoints.firstIndex(where: { $0.hostID == hostID }) else { return }
        activeEndpointIndex = 0
        completedEndpointIndex = 0
        checkpoint = nil
        localRequirement = .identity
        phase = .waiting
        log(
            endpoint: endpoints[index].name,
            message: failure ?? String(localized: "Waiting for an Identity")
        )
    }

    func waitForLocalPassphrase(at hostID: Host.ID, failure: String? = nil) {
        guard let index = endpoints.firstIndex(where: { $0.hostID == hostID }) else { return }
        activeEndpointIndex = 0
        completedEndpointIndex = 0
        checkpoint = nil
        localRequirement = .passphrase
        phase = .waiting
        log(
            endpoint: endpoints[index].name,
            message: failure ?? String(localized: "Waiting for a Passphrase")
        )
    }

    func waitForHostKey(at hostID: Host.ID, fingerprint: String) {
        wait(
            at: hostID, kind: .hostKey,
            message: "Waiting to trust host key " + fingerprint
        )
    }

    func resume() {
        guard phase == .waiting else { return }
        phase = .connecting
        localRequirement = nil
        if let checkpoint {
            log(endpoint: endpoints[checkpoint.endpointIndex].name, message: String(localized: "Continuing connection"))
            completedCheckpoints[checkpoint.endpointIndex] = checkpoint.kind
        }
        checkpoint = nil
    }

    func succeed() {
        guard !endpoints.isEmpty else { return }
        checkpoint = nil
        localRequirement = nil
        completedEndpointIndex = endpoints.count - 1
        activeEndpointIndex = endpoints.count - 1
        phase = .succeeded
        log(endpoint: endpoints.last?.name ?? "", message: String(localized: "Connection ready"))
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.phase = .hidden
        }
    }

    func fail(_ message: String, at hostID: Host.ID? = nil) {
        completionTask?.cancel()
        checkpoint = nil
        localRequirement = nil
        if let hostID,
            let index = endpoints.firstIndex(where: { $0.hostID == hostID })
        {
            activeEndpointIndex = index
        }
        phase = .failed(message)
        let endpoint =
            endpoints.indices.contains(activeEndpointIndex)
            ? endpoints[activeEndpointIndex].name : (endpoints.last?.name ?? "SSH")
        log(endpoint: endpoint, message: "Failed: " + message)
    }

    func hide() {
        completionTask?.cancel()
        checkpoint = nil
        completedCheckpoints = [:]
        localRequirement = nil
        phase = .hidden
    }

    func log(endpoint: String, message: String) {
        logs.append(LogEntry(endpoint: endpoint, message: message))
    }

    var plainTextLog: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return logs.map {
            "[\(formatter.string(from: $0.date))] \($0.endpoint): \($0.message)"
        }.joined(separator: "\n")
    }

    private func wait(at hostID: Host.ID, kind: CheckpointKind, message: String) {
        guard let index = endpoints.firstIndex(where: { $0.hostID == hostID }) else { return }
        activeEndpointIndex = index
        checkpoint = Checkpoint(endpointIndex: index, kind: kind)
        localRequirement = nil
        phase = .waiting
        log(endpoint: endpoints[index].name, message: message)
    }
}

extension ConnectionPurpose {
    fileprivate var logName: String {
        switch self {
        case .sshSession: "SSH session"
        case .sftpSession: "SFTP session"
        case .serialSession: "serial session"
        case .metrics: "metrics"
        }
    }
}
