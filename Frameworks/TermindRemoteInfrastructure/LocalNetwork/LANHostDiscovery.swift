import Darwin
import Foundation
import Network
import TermindApplication
import TermindDomain

@MainActor
public final class LANHostDiscovery: LocalHostDiscovering {
    public let connectionProtocol: LocalDiscoveryProtocol

    public init(connectionProtocol: LocalDiscoveryProtocol = .ssh) {
        self.connectionProtocol = connectionProtocol
    }

    public func discover() async throws -> [DiscoveredLocalHost] {
        let round = DiscoveryRound(connectionProtocol: connectionProtocol)
        return try await round.run()
    }
}

@MainActor
private final class DiscoveryRound: NSObject, @preconcurrency NetServiceDelegate {
    private let connectionProtocol: LocalDiscoveryProtocol
    private var browsers: [NWBrowser] = []
    private var discoveredServices: Set<String> = []
    private var services: [NetService] = []
    private var results: [DiscoveredLocalHost] = []
    private var failure: LocalDiscoveryError?
    private var active = true

    init(connectionProtocol: LocalDiscoveryProtocol) {
        self.connectionProtocol = connectionProtocol
        super.init()
    }

    func run() async throws -> [DiscoveredLocalHost] {
        let candidates = Array(Set(LocalIPv4Interface.current().flatMap(\.scanAddresses))).sorted()
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        let policy = LocalDiscoveryProbePolicy(connectionProtocol: connectionProtocol)
        for type in policy.bonjourServices {
            let parameters = NWParameters.tcp
            parameters.prohibitedInterfaceTypes = [.cellular, .loopback, .other]
            let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in self?.found(results) }
            }
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.active else { return }
                    switch state {
                    case .failed(let error), .waiting(let error):
                        self.failure = error == .dns(-65570) ? .permissionDenied : .failed
                    default: break
                    }
                }
            }
            browsers.append(browser)
            browser.start(queue: .main)
        }
        defer {
            active = false
            for browser in browsers {
                browser.browseResultsChangedHandler = nil
                browser.stateUpdateHandler = nil
                browser.cancel()
            }
            for service in services {
                service.stop()
                service.delegate = nil
            }
        }
        await withTaskGroup(of: (DiscoveredLocalHost?, LocalDiscoveryError?).self) { group in
            var iterator = candidates.makeIterator()
            func enqueue(_ address: String) {
                group.addTask {
                    guard !Task.isCancelled, ContinuousClock.now < deadline else { return (nil, nil) }
                    let probe = await LocalPortProbe(policy: policy)
                    do {
                        let found = try await probe.run(address, deadline: deadline)
                        let host: DiscoveredLocalHost? =
                            found
                            ? .init(
                                name: address, address: address, port: policy.port, source: .probe,
                                connectionProtocol: policy.connectionProtocol) : nil
                        return (host, nil)
                    } catch {
                        return (nil, error as? LocalDiscoveryError)
                    }
                }
            }
            for _ in 0..<min(24, candidates.count) {
                if let address = iterator.next() { enqueue(address) }
            }
            for await (result, error) in group {
                if let result { results.append(result) }
                if let error { failure = error }
                if !Task.isCancelled, ContinuousClock.now < deadline, let address = iterator.next() {
                    enqueue(address)
                }
            }
        }
        if !policy.bonjourServices.isEmpty {
            try await Task.sleep(until: deadline, clock: .continuous)
        }
        try Task.checkCancellation()
        if results.isEmpty, let failure { throw failure }
        // Bonjour can discover IPv6-only peers even when there is no IPv4 interface to sweep.
        if !LocalIPv4Interface.hasPhysicalNetwork, results.isEmpty { throw LocalDiscoveryError.unavailable }
        return results
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        guard active else { return }
        for result in results {
            guard services.count < 200,
                result.interfaces.contains(where: { $0.type == .wifi || $0.type == .wiredEthernet }),
                case .service(let name, let type, let domain, _) = result.endpoint,
                discoveredServices.insert("\(name)|\(type)|\(domain)").inserted
            else { continue }
            let service = NetService(domain: domain, type: type, name: name)
            services.append(service)
            service.delegate = self
            service.resolve(withTimeout: 2)
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard active, let hostname = sender.hostName, !hostname.isEmpty, (1...65_535).contains(sender.port) else {
            return
        }
        let addresses = Set((sender.addresses ?? []).compactMap(Self.numericAddress))
        guard !addresses.isEmpty else { return }
        results.append(
            .init(
                name: sender.name, address: hostname, port: sender.port, source: .bonjour,
                resolvedAddresses: addresses))
    }

    private static func numericAddress(_ data: Data) -> String? {
        data.withUnsafeBytes { bytes in
            guard bytes.count >= MemoryLayout<sockaddr>.size, let base = bytes.baseAddress else { return nil }
            let address = base.assumingMemoryBound(to: sockaddr.self)
            guard address.pointee.sa_len <= bytes.count,
                address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6
            else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                    nil, 0, NI_NUMERICHOST) == 0
            else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()
        }
    }
}

@MainActor
private final class LocalPortProbe {
    private let policy: LocalDiscoveryProbePolicy
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Bool, any Error>?
    private var timeout: Task<Void, Never>?
    private var bytes = Data()

    init(policy: LocalDiscoveryProbePolicy) { self.policy = policy }

    func run(_ address: String, deadline: ContinuousClock.Instant) async throws -> Bool {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
                let parameters = NWParameters.tcp
                // Wired Ethernet is also allowed; excluded interfaces keep probes off VPN/cellular paths.
                parameters.prohibitedInterfaceTypes = [.cellular, .loopback, .other]
                let connection = NWConnection(
                    host: .init(address), port: NWEndpoint.Port(rawValue: UInt16(policy.port))!, using: parameters)
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        switch state {
                        case .ready:
                            guard let self else { return }
                            if self.policy.acceptsConnection(received: self.bytes) {
                                self.finish(true)
                            } else {
                                self.receive()
                            }
                        case .waiting(let error), .failed(let error):
                            guard let self else { return }
                            if self.connection?.currentPath?.unsatisfiedReason == .localNetworkDenied
                                || error == .posix(.EACCES) || error == .posix(.EPERM) || error == .dns(-65570)
                            {
                                self.finish(false, error: .permissionDenied)
                            } else if case .failed = state {
                                self.finish(false)
                            }
                        case .cancelled: self?.finish(false)
                        default: break
                        }
                    }
                }
                timeout = Task { [weak self] in
                    try? await Task.sleep(
                        until: min(deadline, .now.advanced(by: .milliseconds(450))), clock: .continuous)
                    if !Task.isCancelled { self?.finish(false) }
                }
                connection.start(queue: .global(qos: .utility))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(false) }
        }
    }

    private func receive() {
        guard continuation != nil else { return }
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 2048 - bytes.count) {
            [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.continuation != nil else { return }
                if let data { self.bytes.append(data) }
                if self.policy.acceptsConnection(received: self.bytes) {
                    self.finish(true)
                } else if complete || error != nil || self.bytes.count >= 2048 {
                    self.finish(false)
                } else {
                    self.receive()
                }
            }
        }
    }

    private func finish(_ result: Bool, error: LocalDiscoveryError? = nil) {
        let pending = continuation
        continuation = nil
        timeout?.cancel()
        timeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        if let error {
            pending?.resume(throwing: error)
        } else {
            pending?.resume(returning: result)
        }
    }
}

nonisolated struct LocalDiscoveryProbePolicy: Sendable {
    let connectionProtocol: LocalDiscoveryProtocol

    var port: Int { connectionProtocol.port }

    var bonjourServices: [String] {
        connectionProtocol == .ssh ? ["_ssh._tcp", "_sftp-ssh._tcp"] : []
    }

    func acceptsConnection(received data: Data) -> Bool {
        // Telnet discovery is a port scan; unlike SSH, there is no mandatory server-first banner.
        connectionProtocol == .telnet || SSHIdentification.isPresent(in: data)
    }
}

nonisolated enum SSHIdentification {
    static func isPresent(in data: Data) -> Bool {
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        return lines.dropLast().contains { line in
            let identification = line.last == 13 ? line.dropLast() : line[...]
            guard line.count < 255, identification.allSatisfy({ (32...126).contains($0) }),
                let text = String(data: Data(identification), encoding: .ascii)
            else { return false }
            return (text.hasPrefix("SSH-2.0-") || text.hasPrefix("SSH-1.99-"))
                && text.dropFirst(8).first.map { !$0.isWhitespace } == true
        }
    }
}
