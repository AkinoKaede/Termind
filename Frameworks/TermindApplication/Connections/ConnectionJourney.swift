import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated enum ConnectionPurpose: String, Hashable, Sendable {
    case sshSession
    case telnetSession
    case sftpChannel = "sftpSession"
    case serialSession
    case metrics
    case portForwarding
    case keyExport
}

public nonisolated struct ConnectionEndpoint: Identifiable, Hashable, Sendable {
    public nonisolated enum Role: Hashable, Sendable {
        case local
        case jump
        case destination
    }

    public nonisolated enum ID: Hashable, Sendable {
        case local
        case host(Host.ID)
        case serial(String)
    }

    public var id: ID
    public var hostID: Host.ID?
    public var name: String
    public var address: String
    public var role: Role
}

/// UI-facing state for one connection attempt. The transport emits facts; this model
/// turns them into a monotonic route so reconnect probes cannot visually move
/// a completed path backwards.
@Observable
public final class ConnectionJourney {
    public init() {}

    public enum Mode: Equatable {
        case connection
        case reconnection
    }

    public enum Phase: Equatable {
        case hidden
        case connecting
        case waiting
        case succeeded
        case failed(String)
    }

    public enum CheckpointKind: Equatable {
        case authentication
        case hostKey
    }

    public enum LocalRequirement: Equatable {
        case identity
        case tailscaleUsername
        case passphrase
        case proxyAuthentication
    }

    public struct Checkpoint: Equatable {
        public var endpointIndex: Int
        public var kind: CheckpointKind
    }

    public struct LogEntry: Identifiable, Equatable {
        public let id = UUID()
        public var date = Date()
        public var endpoint: String
        public var message: String
    }

    public private(set) var purpose: ConnectionPurpose = .sshSession
    public private(set) var mode: Mode = .connection
    public private(set) var endpoints: [ConnectionEndpoint] = []
    public private(set) var phase: Phase = .hidden
    public private(set) var activeEndpointIndex = 0
    public private(set) var completedEndpointIndex = 0
    public private(set) var checkpoint: Checkpoint?
    public private(set) var completedCheckpoints: [Int: CheckpointKind] = [:]
    public private(set) var localRequirement: LocalRequirement?
    public private(set) var localRequirementEndpointIndex: Int?
    public private(set) var logs: [LogEntry] = []
    public var showsLogs = false

    private var completionTask: Task<Void, Never>?

    public var isPresented: Bool { phase != .hidden }
    public var destination: ConnectionEndpoint? { endpoints.last }
    public var waitsForLocalIdentity: Bool { localRequirement == .identity }
    public var waitsForLocalPassphrase: Bool { localRequirement == .passphrase }
    public var waitsForProxyAuthentication: Bool { localRequirement == .proxyAuthentication }

    private static var localDeviceName: String {
        #if os(macOS)
            String(localized: "This Mac")
        #else
            String(localized: "This Device")
        #endif
    }

    public func begin(
        host: Host, route: [Host], purpose: ConnectionPurpose,
        username: String?, mode: Mode = .connection
    ) {
        completionTask?.cancel()
        let nextEndpoints =
            [
                ConnectionEndpoint(
                    id: .local, hostID: nil,
                    name: Self.localDeviceName, address: "localhost", role: .local
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
        localRequirementEndpointIndex = nil
        logs = retainedLogs
        showsLogs = retainedLogVisibility
        let action = mode == .reconnection ? "Reconnecting " : "Starting "
        log(
            endpoint: endpoints.first?.name ?? Self.localDeviceName,
            message: action + purpose.logName + " connection to " + host.name
        )
        if let username, !username.isEmpty {
            log(endpoint: host.name, message: "Using login " + username)
        }
    }

    public func beginSerial(name: String, address: String, mode: Mode = .connection) {
        completionTask?.cancel()
        purpose = .serialSession
        self.mode = mode
        endpoints = [
            ConnectionEndpoint(
                id: .local, hostID: nil,
                name: Self.localDeviceName, address: "localhost", role: .local
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
        localRequirementEndpointIndex = nil
        logs = []
        showsLogs = false
        log(
            endpoint: endpoints[0].name,
            message: (mode == .reconnection ? "Reconnecting " : "Starting ")
                + "serial connection to " + name
        )
        log(endpoint: name, message: "Opening " + address)
    }

    public func beginTelnet(
        host: Host, username: String?, mode: Mode = .connection
    ) {
        completionTask?.cancel()
        purpose = .telnetSession
        self.mode = mode
        let address = host.displayAddress(for: .telnet)
        endpoints = [
            ConnectionEndpoint(
                id: .local, hostID: nil,
                name: Self.localDeviceName, address: "localhost", role: .local
            ),
            ConnectionEndpoint(
                id: .host(host.id), hostID: host.id, name: host.name,
                address: username?.isEmpty == false ? "\(username!)@\(address)" : address,
                role: .destination
            ),
        ]
        phase = .connecting
        activeEndpointIndex = 0
        completedEndpointIndex = 0
        checkpoint = nil
        completedCheckpoints = [:]
        localRequirement = nil
        localRequirementEndpointIndex = nil
        logs = []
        showsLogs = false
        log(
            endpoint: endpoints[0].name,
            message: (mode == .reconnection ? "Reconnecting " : "Starting ")
                + "Telnet session to " + host.name
        )
        if let username, !username.isEmpty {
            log(endpoint: host.name, message: "Using login " + username)
        }
    }

    public func receive(_ event: TelnetConnectionEvent) {
        guard purpose == .telnetSession, let destination = endpoints.indices.last else { return }
        activeEndpointIndex = destination
        let message: String
        switch event {
        case .openingTransport: message = String(localized: "Opening Telnet transport")
        case .negotiatingOptions: message = String(localized: "Negotiating Telnet options")
        case .configuringCharset: message = String(localized: "Configuring charset")
        case .waitingForUsernamePrompt: message = String(localized: "Waiting for username prompt")
        case .usernameSubmitted: message = String(localized: "Username submitted")
        case .waitingForPasswordPrompt: message = String(localized: "Waiting for password prompt")
        case .passwordSubmitted: message = String(localized: "Password submitted")
        case .continuingManually: message = String(localized: "Continuing with manual login")
        case .connected:
            message = String(localized: "Host connected")
            completedEndpointIndex = destination
        }
        log(endpoint: endpoints[destination].name, message: message)
    }

    public func receive(_ event: SSHRouteEvent) {
        let hostID: Host.ID
        let message: String
        switch event {
        case .proxyConnecting(let id):
            hostID = id
            message = String(localized: "Connecting to proxy")
        case .proxyConnected(let id):
            hostID = id
            message = String(localized: "Proxy connected")
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
        let isProxyEvent: Bool
        switch event {
        case .proxyConnecting, .proxyConnected: isProxyEvent = true
        default: isProxyEvent = false
        }
        let index =
            isProxyEvent
            ? proxySourceEndpointIndex(for: hostID)
            : endpoints.firstIndex { $0.id == .host(hostID) }
        guard let index else { return }

        switch event {
        case .proxyConnecting:
            activeEndpointIndex = max(completedEndpointIndex, index)
        case .connecting, .authenticating, .initializing:
            if index > completedEndpointIndex { activeEndpointIndex = index }
        case .authenticated:
            checkpoint = nil
            activeEndpointIndex = max(activeEndpointIndex, index)
        case .proxyConnected:
            break
        case .connected:
            checkpoint = nil
            completedEndpointIndex = max(completedEndpointIndex, index)
            activeEndpointIndex = max(activeEndpointIndex, index)
        }
        log(endpoint: endpoints[index].name, message: message)
    }

    public func waitForAuthentication(at hostID: Host.ID, failure: String? = nil) {
        wait(at: hostID, kind: .authentication, message: failure ?? String(localized: "Waiting for authentication"))
    }

    public func waitForProxyAuthentication(at hostID: Host.ID, failure: String? = nil) {
        guard let index = proxySourceEndpointIndex(for: hostID) else { return }
        activeEndpointIndex = index
        checkpoint = nil
        localRequirement = .proxyAuthentication
        localRequirementEndpointIndex = index
        phase = .waiting
        log(
            endpoint: endpoints[index].name,
            message: failure ?? String(localized: "Waiting for proxy authentication")
        )
    }

    /// Pauses before transport authentication because Termind has no usable local
    /// Identity. This is not a server challenge, so the untouched route stays
    /// gray and no midpoint checkpoint is introduced.
    public func waitForLocalIdentity(at hostID: Host.ID, failure: String? = nil) {
        guard let index = endpoints.firstIndex(where: { $0.id == .host(hostID) }) else { return }
        activeEndpointIndex = 0
        completedEndpointIndex = 0
        checkpoint = nil
        localRequirement = .identity
        localRequirementEndpointIndex = 0
        phase = .waiting
        log(
            endpoint: endpoints[index].name,
            message: failure ?? String(localized: "Waiting for an Identity")
        )
    }

    public func waitForTailscaleUsername(at hostID: Host.ID, failure: String? = nil) {
        waitForLocalIdentity(at: hostID, failure: failure ?? String(localized: "Username"))
        localRequirement = .tailscaleUsername
    }

    public func waitForLocalPassphrase(at hostID: Host.ID, failure: String? = nil) {
        guard let index = endpoints.firstIndex(where: { $0.id == .host(hostID) }) else { return }
        activeEndpointIndex = 0
        completedEndpointIndex = 0
        checkpoint = nil
        localRequirement = .passphrase
        localRequirementEndpointIndex = 0
        phase = .waiting
        log(
            endpoint: endpoints[index].name,
            message: failure ?? String(localized: "Waiting for a Passphrase")
        )
    }

    public func waitForHostKey(at hostID: Host.ID, fingerprint: String) {
        wait(
            at: hostID, kind: .hostKey,
            message: "Waiting to trust host key " + fingerprint
        )
    }

    public func waitForSessionSelection() {
        guard phase == .connecting || phase == .waiting, !endpoints.isEmpty else { return }
        checkpoint = nil
        localRequirement = nil
        localRequirementEndpointIndex = nil
        activeEndpointIndex = endpoints.count - 1
        phase = .waiting
    }

    public func resume() {
        guard phase == .waiting else { return }
        phase = .connecting
        localRequirement = nil
        localRequirementEndpointIndex = nil
        if let checkpoint {
            log(endpoint: endpoints[checkpoint.endpointIndex].name, message: String(localized: "Continuing connection"))
            completedCheckpoints[checkpoint.endpointIndex] = checkpoint.kind
        }
        checkpoint = nil
    }

    public func succeed() {
        guard !endpoints.isEmpty else { return }
        checkpoint = nil
        localRequirement = nil
        localRequirementEndpointIndex = nil
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

    public func fail(_ message: String, at hostID: Host.ID? = nil) {
        completionTask?.cancel()
        checkpoint = nil
        localRequirement = nil
        localRequirementEndpointIndex = nil
        if let hostID,
            let index = endpoints.firstIndex(where: { $0.id == .host(hostID) })
        {
            activeEndpointIndex = index
        }
        phase = .failed(message)
        let endpoint =
            endpoints.indices.contains(activeEndpointIndex)
            ? endpoints[activeEndpointIndex].name : (endpoints.last?.name ?? "SSH")
        log(endpoint: endpoint, message: "Failed: " + message)
    }

    public func hide() {
        completionTask?.cancel()
        checkpoint = nil
        completedCheckpoints = [:]
        localRequirement = nil
        localRequirementEndpointIndex = nil
        phase = .hidden
    }

    public func log(endpoint: String, message: String) {
        logs.append(LogEntry(endpoint: endpoint, message: message))
    }

    public var plainTextLog: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return logs.map {
            "[\(formatter.string(from: $0.date))] \($0.endpoint): \($0.message)"
        }.joined(separator: "\n")
    }

    private func wait(at hostID: Host.ID, kind: CheckpointKind, message: String) {
        guard let index = endpoints.firstIndex(where: { $0.id == .host(hostID) }) else { return }
        activeEndpointIndex = index
        checkpoint = Checkpoint(endpointIndex: index, kind: kind)
        localRequirement = nil
        localRequirementEndpointIndex = nil
        phase = .waiting
        log(endpoint: endpoints[index].name, message: message)
    }

    private func proxySourceEndpointIndex(for hostID: Host.ID) -> Int? {
        guard let targetIndex = endpoints.firstIndex(where: { $0.id == .host(hostID) }), targetIndex > 0 else {
            return nil
        }
        return targetIndex - 1
    }
}

extension ConnectionPurpose {
    fileprivate var logName: String {
        switch self {
        case .sshSession: "SSH session"
        case .telnetSession: "Telnet session"
        case .sftpChannel: "SFTP channel"
        case .serialSession: "serial session"
        case .metrics: "metrics"
        case .portForwarding: "port forwarding"
        case .keyExport: "key export"
        }
    }
}
