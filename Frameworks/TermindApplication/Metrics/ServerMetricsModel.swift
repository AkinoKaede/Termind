import Foundation
import TermindDomain

import struct TermindDomain.Host

@Observable
public final class ServerMetric: Identifiable {
    public nonisolated let id: UUID
    public var selection: MetricsSelection
    public var name: String
    public var status = String(localized: "Connecting…")
    public var collectionState = MetricsMonitorState.connecting
    public var isConnecting = true
    public var point: MetricsPoint?
    public var history: [MetricsPoint] = []
    public var disks: [String] = []
    public var interfaces: [String] = []
    public var gpuState = MetricsGPUState.probing
    public var gpuSnapshot: NvidiaSnapshot?
    public var gpuDate: Date?
    public var authenticationHost: Host?
    public var hostKey: SSHHostKeyObservation?
    public var needsAttention = false
    public let journey = ConnectionJourney()
    public var authenticationPrompt: SSHAuthenticationPrompt?
    public var hostKeyPrompt: SSHHostKeyPrompt?
    public var hostKeyHostID: UUID?
    public var requiresAuthentication: Bool { hostKey != nil || authenticationPrompt != nil }
    public var showsConnectionJourney: Bool { requiresAuthentication || journey.isPresented }
    public var processes: [MetricsProcess] = []
    public var processesDate: Date?
    public var processesFailed = false
    public var filesystems: [MetricsFilesystem] = []
    public var filesystemsFailed = false
    public var filesystemsDate: Date?

    public init(selection: MetricsSelection, name: String) {
        id = selection.id
        self.selection = selection
        self.name = name
    }
}

/// One application owner, independent of windows, with one serial worker per host.
@MainActor
@Observable
public final class ServerMetricsModel: MetricsSnapshotReading {
    public static let freeCardLimit = 3
    public private(set) var servers: [ServerMetric] = []
    public private(set) var sleeping = false
    private var started = false
    private var stopped = false
    private let hosts: any RemoteSessionHostStore
    private let preferences: any MetricsConfigurationStoring
    private let makeSampler: @Sendable () -> any MetricsSampling
    private let discover:
        @Sendable (Host, SSHTransportProxy?, [SSHRouteHopConfiguration]) async throws -> SSHHostKeyObservation
    private let clock: MetricsClock
    private let cardLimit: () -> Int?
    private let limitReached: () -> Void
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UUID] = [:]
    private var samplers: [UUID: any MetricsSampling] = [:]
    private var submissions: [UUID: [UUID: SSHAuthenticationSubmission]] = [:]
    private var maintenance: Task<Void, Never>?
    private var detailObservers: [UUID: UUID] = [:]
    private var temporaryKeys: [UUID: [UUID: SSHHostKeyIdentity]] = [:]
    private var stamps: [UUID: Data] = [:]

    public var keepsRunning: Bool { servers.contains { $0.selection.enabled } }

    public init(
        hosts: any RemoteSessionHostStore, preferences: any MetricsConfigurationStoring,
        makeSampler: @escaping @Sendable () -> any MetricsSampling,
        discover:
            @escaping @Sendable (Host, SSHTransportProxy?, [SSHRouteHopConfiguration]) async throws ->
            SSHHostKeyObservation,
        clock: MetricsClock = MetricsClock(),
        cardLimit: @escaping () -> Int? = { ServerMetricsModel.freeCardLimit },
        limitReached: @escaping () -> Void = {}
    ) {
        self.hosts = hosts
        self.preferences = preferences
        self.makeSampler = makeSampler
        self.discover = discover
        self.clock = clock
        self.cardLimit = cardLimit
        self.limitReached = limitReached
    }

    public func snapshot(for hostID: UUID) -> MetricsSnapshot? {
        guard hosts.host(hostID) != nil, let server = servers.first(where: { $0.id == hostID }) else { return nil }
        let state: MetricsMonitorState
        if !server.selection.enabled {
            state = .paused
        } else if sleeping {
            state = .sleeping
        } else if stopped {
            state = .stopped
        } else if server.requiresAuthentication {
            state = .awaitingAuthentication
        } else {
            state = server.collectionState
        }
        return MetricsSnapshot(
            capturedAt: clock.now(), state: state, point: server.point, history: server.history,
            gpuState: server.gpuState, gpu: server.gpuSnapshot, gpuDate: server.gpuDate,
            processes: server.processes, processesDate: server.processesDate,
            processesFailed: server.processesFailed, filesystems: server.filesystems,
            filesystemsDate: server.filesystemsDate, filesystemsFailed: server.filesystemsFailed
        )
    }

    public var remainingCardSlots: Int? { cardLimit().map { max(0, $0 - servers.count) } }

    #if DEBUG
        /// Frozen product fixtures never load preferences or start an SSH worker.
        public convenience init(screenshotHosts: any RemoteSessionHostStore, rows: [ServerMetric]) {
            self.init(
                hosts: screenshotHosts, preferences: ScreenshotMetricsPreferences(),
                makeSampler: { preconditionFailure("Screenshot metrics cannot connect") },
                discover: { _, _, _ in preconditionFailure("Screenshot metrics cannot discover hosts") },
                cardLimit: { nil }
            )
            servers = rows
            started = true
            stopped = true
        }
    #endif

    @discardableResult
    public func requestAddition(count: Int = 1) -> Bool {
        guard count > 0 else { return true }
        guard let remaining = remainingCardSlots, count > remaining else { return true }
        limitReached()
        return false
    }

    public func observeDetails(hostID: UUID, observer: UUID) { detailObservers[observer] = hostID }
    public func stopObservingDetails(_ observer: UUID) { detailObservers[observer] = nil }

    public func start() {
        guard !started else { return }
        started = true
        var seen = Set<UUID>()
        servers = preferences.load().filter { seen.insert($0.id).inserted }.compactMap { selection in
            guard let host = hosts.host(selection.id) else { return nil }
            return ServerMetric(selection: selection, name: host.name)
        }
        for server in servers { launch(server) }
        // Keep the timer independent, but make the executor hop explicit at the
        // boundary before touching Metrics or its MainActor host store.
        maintenance = Task.detached { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(2) } catch { return }
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.reconcile() }
            }
        }
    }

    @discardableResult
    public func add(_ host: Host) -> Bool { add([host]) }

    /// Admission and insertion are one MainActor operation, shared by all windows.
    @discardableResult
    public func add(_ hosts: [Host]) -> Bool {
        var seen = Set(servers.map(\.id))
        let additions = hosts.filter { seen.insert($0.id).inserted }
        guard requestAddition(count: additions.count) else { return false }
        guard !additions.isEmpty else { return true }
        let rows = additions.map { ServerMetric(selection: MetricsSelection(id: $0.id), name: $0.name) }
        servers.append(contentsOf: rows)
        save()
        for server in rows { launch(server) }
        return true
    }

    public func move(_ ids: [UUID], before next: UUID?) {
        let wanted = Set(ids)
        let moving = servers.filter { wanted.contains($0.id) }
        guard !moving.isEmpty, next.map({ !wanted.contains($0) }) ?? true else { return }
        var ordered = servers.filter { !wanted.contains($0.id) }
        let index = next.flatMap { id in ordered.firstIndex { $0.id == id } } ?? ordered.count
        ordered.insert(contentsOf: moving, at: index)
        guard ordered.map(\.id) != servers.map(\.id) else { return }
        servers = ordered
        save()
    }

    public func remove(_ id: UUID) {
        cancel(id)
        submissions[id] = nil
        temporaryKeys[id] = nil
        stamps[id] = nil
        detailObservers = detailObservers.filter { $0.value != id }
        servers.removeAll { $0.id == id }
        save()
    }

    public func setEnabled(_ enabled: Bool, for server: ServerMetric) {
        server.selection.enabled = enabled
        cancel(server.id)
        server.isConnecting = false
        server.authenticationHost = nil
        server.hostKey = nil
        server.needsAttention = false
        if !enabled {
            submissions[server.id] = nil
            temporaryKeys[server.id] = nil
            server.journey.hide()
        }
        server.authenticationPrompt = nil
        server.hostKeyPrompt = nil
        save()
        launch(server)
    }

    public func retry(_ server: ServerMetric) {
        server.journey.resume()
        server.authenticationPrompt = nil
        server.hostKeyPrompt = nil
        cancel(server.id)
        server.isConnecting = false
        server.authenticationHost = nil
        server.hostKey = nil
        server.needsAttention = false
        launch(server)
    }

    public func selectDevices(_ server: ServerMetric, disks: Set<String>?, interfaces: Set<String>?) {
        server.selection.disks = disks
        server.selection.interfaces = interfaces
        server.history = []
        server.point = nil
        save()
        retry(server)
    }

    public func submitAuthentication(
        _ server: ServerMetric, identityID: UUID?, username: String, password: String?,
        passphrase: String?, keyID: UUID?, save: Bool
    ) {
        guard var host = server.authenticationHost else { return }
        let identity = identityID.flatMap { hosts.identity($0) }
        let name = (identity?.username ?? username).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if server.authenticationPrompt?.requiresPassphrase == true,
            var staged = submissions[server.id]?[host.id]
        {
            guard let passphrase, !passphrase.isEmpty else { return }
            staged.passphrase = passphrase
            submissions[server.id]?[host.id] = staged
            retry(server)
            return
        }
        let chosenKey = identity?.keyID ?? keyID
        if save {
            let saved = identity ?? Identity(name: name, username: name, keyID: chosenKey)
            do {
                try hosts.upsert(saved, passwordUpdate: password.map(IdentityPasswordUpdate.replace) ?? .keep)
                host.identityID = saved.id
                hosts.upsert(host)
            } catch {
                server.status = error.localizedDescription
                server.collectionState = .failed
                server.journey.fail(error.localizedDescription, at: host.id)
                return
            }
        }
        submissions[server.id, default: [:]][host.id] = SSHAuthenticationSubmission(
            username: name, password: password, passphrase: passphrase,
            keyID: chosenKey, identityID: identity?.id
        )
        retry(server)
    }

    public func acceptHostKey(_ server: ServerMetric, observation: SSHHostKeyObservation, remember: Bool) {
        guard server.hostKey == observation, let hostID = server.hostKeyHostID else { return }
        if remember {
            hosts.trust(
                KnownHostEntry(
                    hostname: observation.hostname, port: observation.port,
                    algorithm: observation.algorithm, fingerprint: observation.fingerprint, addedAt: clock.now()
                ))
        } else {
            temporaryKeys[server.id, default: [:]][hostID] = observation.identity
        }
        retry(server)
    }

    private func preparation(for host: Host, server: ServerMetric) throws -> SSHConnectionPreparation {
        var result = try hosts.prepareSSHConnection(for: host, submissions: submissions[server.id] ?? [:])
        for index in result.nodes.indices {
            if let key = temporaryKeys[server.id]?[result.nodes[index].host.id] {
                result.nodes[index].trustedKeys.insert(key)
            }
        }
        return result
    }

    private func requestAuthentication(_ server: ServerMetric, hostID: UUID, error: TermindSSHError) {
        guard let host = hosts.host(hostID) else { return }
        let staged = submissions[server.id]?[host.id]
        let identity = staged?.identityID.flatMap { hosts.identity($0) } ?? hosts.identity(for: host)
        let keyID = staged?.keyID ?? identity?.keyID
        let passphrase = keyID.flatMap { hosts.key($0) }?.requiresPassphraseEntry == true && staged?.passphrase == nil
        server.authenticationHost = host
        server.authenticationPrompt = SSHAuthenticationPrompt(
            host: host, selectedIdentityID: identity?.id, username: staged?.username ?? identity?.username ?? "",
            selectedKeyID: keyID, failureMessage: error.localizedDescription, requiresPassphrase: passphrase,
            mode: error.isServerAuthenticationChallenge ? .serverChallenge : .localIdentity
        )
        server.needsAttention = true
        if error.isServerAuthenticationChallenge {
            server.journey.waitForAuthentication(at: host.id, failure: error.localizedDescription)
        } else if passphrase {
            server.journey.waitForLocalPassphrase(at: host.id, failure: error.localizedDescription)
        } else {
            server.journey.waitForLocalIdentity(at: host.id, failure: error.localizedDescription)
        }
    }

    public func suspend() {
        sleeping = true
        for server in servers {
            cancel(server.id)
            server.isConnecting = false
            if server.selection.enabled { server.status = String(localized: "Sleeping") }
        }
    }

    public func resume() {
        guard sleeping else { return }
        sleeping = false
        reconcile()
        for server in servers { launch(server) }
    }

    public func shutdown() {
        stopped = true
        maintenance?.cancel()
        maintenance = nil
        for server in servers { cancel(server.id) }
        submissions = [:]
        temporaryKeys = [:]
        for server in servers { server.journey.hide() }
    }

    public func reconcile() {
        for server in servers {
            guard let host = hosts.host(server.id) else {
                remove(server.id)
                continue
            }
            server.name = host.name
            server.history.removeAll { $0.date < clock.now().addingTimeInterval(-300) }
            let stamp = connectionStamp(host)
            if let old = stamps[server.id], old != stamp {
                submissions[server.id] = nil
                temporaryKeys[server.id] = nil
                retry(server)
            }
            stamps[server.id] = stamp
        }
    }

    private func connectionStamp(_ host: Host) -> Data {
        // Values contain key references and public material, never resolved secrets.
        let route = hosts.route(for: host)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var result = (try? encoder.encode(route)) ?? Data()
        for item in route {
            if let identity = hosts.identity(for: item) {
                result.append((try? encoder.encode(identity)) ?? Data())
                if let id = identity.keyID, let key = hosts.key(id) {
                    result.append((try? encoder.encode(key)) ?? Data())
                }
            }
        }
        return result
    }

    private func save() { preferences.save(servers.map(\.selection)) }

    private func cancel(_ id: UUID) {
        generations[id] = nil
        workers.removeValue(forKey: id)?.cancel()
        if let sampler = samplers.removeValue(forKey: id) {
            Task { await sampler.disconnect() }
        }
    }

    private func launch(_ server: ServerMetric) {
        guard !stopped, !sleeping, server.selection.enabled, !server.needsAttention else {
            if !server.selection.enabled { server.status = String(localized: "Paused") }
            return
        }
        guard workers[server.id] == nil else { return }
        guard let host = hosts.host(server.id) else {
            let message = String(localized: "The host is no longer available.")
            server.isConnecting = false
            server.status = message
            server.collectionState = .failed
            server.journey.fail(message)
            return
        }
        beginConnectionJourney(for: server, host: host)
        let token = UUID()
        generations[server.id] = token
        server.isConnecting = true
        server.status = String(localized: "Connecting…")
        server.collectionState = .connecting
        server.gpuState = .probing
        stamps[server.id] = connectionStamp(host)
        workers[server.id] = Task { [weak self] in await self?.run(server, token: token) }
    }

    private func beginConnectionJourney(for server: ServerMetric, host: Host) {
        server.journey.begin(
            host: host, route: hosts.route(for: host), purpose: .metrics,
            username: submissions[server.id]?[host.id]?.username ?? hosts.identity(for: host)?.username
        )
    }

    private func current(_ server: ServerMetric, _ token: UUID) -> Bool {
        !Task.isCancelled && generations[server.id] == token && !stopped && !sleeping
    }

    private func run(_ server: ServerMetric, token: UUID) async {
        var delay = 2.0
        while current(server, token) {
            let sampler = makeSampler()
            samplers[server.id] = sampler
            do {
                guard let host = hosts.host(server.id) else { return }
                if server.journey.phase != .connecting {
                    beginConnectionJourney(for: server, host: host)
                }
                server.status = String(localized: "Connecting…")
                server.collectionState = .connecting
                server.isConnecting = true
                let configuration = try await preparation(for: host, server: server).resolve()
                guard current(server, token) else { return }
                try await sampler.connect(configuration)
                guard current(server, token) else {
                    await sampler.disconnect()
                    return
                }
                server.isConnecting = false
                server.journey.receive(.connected(host.id))
                server.status = String(localized: "Connected — collecting metrics…")
                server.collectionState = .collecting
                var previous: MetricsSample?
                var previousProcesses: MetricsProcessSample?
                var nextFilesystemRefresh = Date.distantPast
                var probeGPU = true
                while current(server, token) {
                    let began = clock.now()
                    let sample = try await sampler.sample()
                    guard current(server, token) else { break }
                    var point = MetricsCalculation.point(
                        previous: previous, current: sample, selection: server.selection, date: clock.now()
                    )
                    previous = sample
                    server.disks = sample.disks.map { $0.keys.sorted() } ?? server.disks
                    server.interfaces = sample.interfaces.map { $0.keys.sorted() } ?? server.interfaces
                    server.status = String(localized: "Live")
                    server.collectionState = .live
                    if server.journey.phase == .connecting { server.journey.succeed() }
                    // Publish base metrics before the optional, bounded GPU command.
                    server.point = point
                    delay = 2
                    if probeGPU {
                        do {
                            let gpu = try await sampler.gpu()
                            guard current(server, token) else { break }
                            server.gpuSnapshot = gpu
                            server.gpuDate = clock.now()
                            let devices = gpu?.devices ?? []
                            probeGPU = !devices.isEmpty
                            server.gpuState = devices.isEmpty ? .unavailable : .available
                            let ids = Set(devices.map(\.id))
                            for index in server.history.indices {
                                server.history[index].gpus.removeAll { !ids.contains($0.id) }
                            }
                            point.gpus = devices
                        } catch {
                            guard current(server, token) else { break }
                            server.gpuState = .failed
                            // Unknown GPU values create a gap, not a false zero or a repeated stale sample.
                        }
                    }
                    if detailObservers.values.contains(server.id) {
                        if clock.now() >= nextFilesystemRefresh {
                            do {
                                if let filesystems = try await sampler.filesystems() {
                                    guard current(server, token) else { break }
                                    server.filesystems = filesystems
                                    server.filesystemsDate = clock.now()
                                    server.filesystemsFailed = false
                                }
                            } catch {
                                guard current(server, token) else { break }
                                server.filesystemsFailed = true
                            }
                            nextFilesystemRefresh = clock.now().addingTimeInterval(30)
                        }
                        do {
                            if let processes = try await sampler.processes() {
                                guard current(server, token) else { break }
                                server.processes = MetricsProcess.rows(previous: previousProcesses, current: processes)
                                previousProcesses = processes
                                server.processesDate = clock.now()
                                server.processesFailed = false
                            }
                        } catch {
                            guard current(server, token) else { break }
                            server.processesFailed = true
                            previousProcesses = nil
                        }
                    } else {
                        previousProcesses = nil
                    }
                    server.point = point
                    server.history.append(point)
                    server.history.removeAll { $0.date < clock.now().addingTimeInterval(-300) }
                    try await clock.sleep(min(2, max(0.05, 2 - clock.now().timeIntervalSince(began))))
                }
            } catch {
                guard current(server, token) else {
                    await sampler.disconnect()
                    return
                }
                server.isConnecting = false
                server.status = error.localizedDescription
                server.collectionState = .failed
                if let ssh = error as? TermindSSHError {
                    let targetID = ssh.routeHostID ?? server.id
                    if ssh.isLocalAuthenticationRequirement || ssh.shouldRequestAuthentication {
                        requestAuthentication(server, hostID: targetID, error: ssh)
                    } else if ssh.shouldRequestHostKey || ssh.isHostKeyChanged
                        || isTrustRequirement(ssh)
                    {
                        await requestTrust(server, hostID: targetID, token: token)
                    }
                }
                if case MetricsReadError.unsupported = error { server.needsAttention = true }
                if !server.requiresAuthentication { server.journey.fail(error.localizedDescription) }
            }
            await sampler.disconnect()
            guard current(server, token) else { return }
            if server.needsAttention {
                workers[server.id] = nil
                samplers[server.id] = nil
                return
            }
            do { try await clock.sleep(delay) } catch { return }
            delay = min(60, delay * 2)
        }
    }

    private func isTrustRequirement(_ error: TermindSSHError) -> Bool {
        switch error {
        case .untrustedHost, .mismatchedHostKey: true
        default: false
        }
    }

    private func requestTrust(_ server: ServerMetric, hostID: UUID, token: UUID, visited: Set<UUID> = []) async {
        guard !visited.contains(hostID), visited.count < 16 else {
            server.needsAttention = true
            return
        }
        guard let host = hosts.host(hostID) else { return }
        do {
            let configuration = try await preparation(for: host, server: server).resolve(discoveryOnly: true)
            guard current(server, token) else { return }
            let observation = try await discover(host, configuration.proxy, configuration.jumps)
            guard current(server, token) else { return }
            server.hostKey = observation
            server.hostKeyHostID = host.id
            let trustedCount = hosts.knownHosts(for: host).count
            server.hostKeyPrompt = SSHHostKeyPrompt(
                observation: observation,
                kind: trustedCount == 0 ? .firstUse : .additionalKey(trustedKeyCount: trustedCount)
            )
            server.status = String(localized: "Server Identity Verification Required")
            server.needsAttention = true
            server.journey.waitForHostKey(at: host.id, fingerprint: observation.fingerprint)
        } catch {
            guard current(server, token) else { return }
            server.status = error.localizedDescription
            server.collectionState = .failed
            if let ssh = error as? TermindSSHError, ssh.shouldRequestAuthentication {
                requestAuthentication(server, hostID: ssh.routeHostID ?? hostID, error: ssh)
            } else if let ssh = error as? TermindSSHError, ssh.shouldRequestHostKey,
                let next = ssh.routeHostID
            {
                await requestTrust(server, hostID: next, token: token, visited: visited.union([hostID]))
            }
        }
    }
}

#if DEBUG
    private final class ScreenshotMetricsPreferences: MetricsConfigurationStoring {
        func load() -> [MetricsSelection] { [] }
        func save(_ selections: [MetricsSelection]) {}
    }
#endif
