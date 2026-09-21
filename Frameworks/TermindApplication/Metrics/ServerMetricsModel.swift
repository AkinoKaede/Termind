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
    public let keyboardAuthentication = SSHKeyboardInteractiveQueue()
    public var authenticationPrompt: SSHAuthenticationPrompt?
    public var hostKeyPrompt: SSHHostKeyPrompt?
    public var hostKeyHostID: UUID?
    public var requiresAuthentication: Bool {
        hostKey != nil || authenticationPrompt != nil || keyboardAuthentication.current != nil
    }
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
    public private(set) var storageError: String?
    public var selections: [MetricsSelection] { configuredSelections }
    private var started = false
    private var stopped = false
    private var configuredSelections: [MetricsSelection] = []
    private let hosts: any RemoteSessionHostStore
    private let preferences: any MetricsConfigurationStoring
    private let makeSampler: @Sendable () -> any MetricsSampling
    private let clock: MetricsClock
    private let cardLimit: () -> Int?
    private let limitReached: () -> Void
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UUID] = [:]
    private var samplers: [UUID: any MetricsSampling] = [:]
    private var submissions: [UUID: [UUID: SSHAuthenticationSubmission]] = [:]
    private var proxySubmissions: [UUID: [UUID: SSHProxyAuthenticationSubmission]] = [:]
    private var maintenance: Task<Void, Never>?
    private var detailObservers: [UUID: UUID] = [:]
    private var temporaryKeys: [UUID: [UUID: SSHHostKeyIdentity]] = [:]
    private var stamps: [UUID: Data] = [:]
    private struct PendingHostKeyAuthorization {
        var id: UUID
        var continuation: AsyncStream<SSHHostKeyDecision>.Continuation
    }
    private struct PendingKeyboardAuthentication {
        var id: UUID
        var task: Task<[String], any Error>
    }
    private nonisolated struct RunAttempt: Sendable {
        var host: Host
        var preparation: SSHConnectionPreparation?
        var sampler: any MetricsSampling
    }
    private nonisolated struct HostKeyAuthorization: Sendable {
        var id: UUID
        var decisions: AsyncStream<SSHHostKeyDecision>
    }
    private nonisolated enum RunCycleDisposition: Sendable {
        case stop, attention, retry
    }
    private var pendingHostKeyAuthorizations: [UUID: PendingHostKeyAuthorization] = [:]
    private var pendingKeyboardAuthentications: [UUID: PendingKeyboardAuthentication] = [:]

    public var keepsRunning: Bool { servers.contains { $0.selection.enabled } }

    public init(
        hosts: any RemoteSessionHostStore, preferences: any MetricsConfigurationStoring,
        makeSampler: @escaping @Sendable () -> any MetricsSampling,
        clock: MetricsClock = MetricsClock(),
        cardLimit: @escaping () -> Int? = { ServerMetricsModel.freeCardLimit },
        limitReached: @escaping () -> Void = {}
    ) {
        self.hosts = hosts
        self.preferences = preferences
        self.makeSampler = makeSampler
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

    public var remainingCardSlots: Int? { cardLimit().map { max(0, $0 - configuredSelections.count) } }

    #if DEBUG
        /// Frozen product fixtures never load preferences or start an SSH worker.
        public convenience init(screenshotHosts: any RemoteSessionHostStore, rows: [ServerMetric]) {
            self.init(
                hosts: screenshotHosts, preferences: ScreenshotMetricsPreferences(),
                makeSampler: { preconditionFailure("Screenshot metrics cannot connect") },
                cardLimit: { nil }
            )
            servers = rows
            configuredSelections = rows.map(\.selection)
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
        do {
            configuredSelections = Self.deduplicated(try preferences.load())
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
        applyConfiguration(configuredSelections)
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
        var seen = Set(configuredSelections.map(\.id))
        let additions = hosts.filter { seen.insert($0.id).inserted }
        guard requestAddition(count: additions.count) else { return false }
        let next = configuredSelections + additions.map { MetricsSelection(id: $0.id) }
        guard persist(next) else { return false }
        applyConfiguration(next)
        return true
    }

    public func move(_ ids: [UUID], before next: UUID?) {
        let wanted = Set(ids)
        let moving = configuredSelections.filter { wanted.contains($0.id) }
        guard !moving.isEmpty, next.map({ !wanted.contains($0) }) ?? true else { return }
        var ordered = configuredSelections.filter { !wanted.contains($0.id) }
        let index = next.flatMap { id in ordered.firstIndex { $0.id == id } } ?? ordered.count
        ordered.insert(contentsOf: moving, at: index)
        guard ordered.map(\.id) != configuredSelections.map(\.id), persist(ordered) else { return }
        applyConfiguration(ordered)
    }

    public func remove(_ id: UUID) {
        let next = configuredSelections.filter { $0.id != id }
        guard next.count != configuredSelections.count, persist(next) else { return }
        applyConfiguration(next)
    }

    public func setEnabled(_ enabled: Bool, for server: ServerMetric) {
        guard let index = configuredSelections.firstIndex(where: { $0.id == server.id }) else { return }
        var next = configuredSelections
        next[index].enabled = enabled
        guard next != configuredSelections, persist(next) else { return }
        applyConfiguration(next)
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
        guard let index = configuredSelections.firstIndex(where: { $0.id == server.id }) else { return }
        var next = configuredSelections
        next[index].disks = disks
        next[index].interfaces = interfaces
        guard next != configuredSelections, persist(next) else { return }
        applyConfiguration(next)
    }

    public func applyRemoteSnapshot(_ snapshot: MetricsSyncSnapshot) {
        let next = Self.deduplicated(snapshot.selections)
        configuredSelections = next
        storageError = nil
        if started { applyConfiguration(next) }
    }

    public func submitAuthentication(
        _ server: ServerMetric, identityID: UUID?, username: String, password: String?,
        passphrase: String?, keyID: UUID?, save: Bool
    ) {
        guard var host = server.authenticationHost else { return }
        let identity = identityID.flatMap { hosts.identity($0) }
        let isProxy = server.authenticationPrompt?.isProxy == true
        let name = ((isProxy ? nil : identity?.username) ?? username)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if isProxy {
            let submission = SSHProxyAuthenticationSubmission(
                username: name, password: password, identityID: identity?.id)
            do {
                if save {
                    host = try hosts.saveProxyAuthentication(
                        submission, for: host, selectedIdentity: identity,
                        suppliedPassword: password)
                }
                proxySubmissions[server.id, default: [:]][host.id] = submission
                retry(server)
            } catch {
                server.status = error.localizedDescription
                server.collectionState = .failed
                server.journey.fail(error.localizedDescription, at: host.id)
            }
            return
        }
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
        server.hostKey = nil
        server.hostKeyHostID = nil
        server.hostKeyPrompt = nil
        server.needsAttention = false
        server.journey.resume()
        finishHostKeyAuthorization(for: server.id, decision: .accept)
    }

    private func preparation(
        for host: Host, server: ServerMetric,
        submissions: [UUID: SSHAuthenticationSubmission],
        proxySubmissions: [UUID: SSHProxyAuthenticationSubmission]
    ) throws -> SSHConnectionPreparation {
        try hosts.prepareSSHConnection(
            for: host,
            submissions: submissions,
            proxySubmissions: proxySubmissions,
            temporaryHostKeys: temporaryKeys[server.id] ?? [:]
        )
    }

    private func requestAuthentication(_ server: ServerMetric, hostID: UUID, error: TermindSSHError) {
        guard let host = hosts.host(hostID) else { return }
        if error.isProxyAuthentication, let proxy = host.proxy {
            let staged = proxySubmissions[server.id]?[host.id]
            let configured = (staged?.identityID ?? proxy.identityID).flatMap { hosts.identity($0) }
            let selected: Identity?
            if let configured {
                switch hosts.passwordAvailability(for: configured) {
                case .available, .notConfigured: selected = configured
                case .missing, .failed: selected = nil
                }
            } else {
                selected = nil
            }
            server.authenticationHost = host
            server.authenticationPrompt = SSHAuthenticationPrompt(
                host: Host(
                    id: host.id, name: String(localized: "Proxy for \(host.name)"),
                    host: proxy.hostname, port: proxy.port),
                selectedIdentityID: selected?.id,
                username: staged?.username ?? proxy.username,
                failureMessage: error.localizedDescription,
                mode: error.isServerAuthenticationChallenge ? .serverChallenge : .localIdentity,
                target: .proxy(ownerHostID: host.id))
            server.needsAttention = true
            server.journey.waitForProxyAuthentication(at: host.id, failure: error.localizedDescription)
            return
        }
        let staged = submissions[server.id]?[host.id]
        let identity = staged?.identityID.flatMap { hosts.identity($0) } ?? hosts.identity(for: host)
        let keyID = staged?.keyID ?? identity?.keyID
        let passphrase =
            staged?.requiresPasswordReentry != true
            && keyID.flatMap { hosts.key($0) }?.requiresPassphraseEntry == true
            && staged?.passphrase == nil
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
        submissions.removeAll()
        proxySubmissions.removeAll()
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
        applyConfiguration(configuredSelections)
        for server in servers {
            guard let host = hosts.host(server.id) else { continue }
            server.name = host.name
            server.history.removeAll { $0.date < clock.now().addingTimeInterval(-300) }
            let stamp = connectionStamp(host)
            if let old = stamps[server.id], old != stamp {
                submissions[server.id] = nil
                proxySubmissions[server.id] = nil
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
            if var identity = hosts.identity(for: item) {
                // Credential access updates presentation metadata after a connection
                // is prepared. It must not make Metrics mistake that same connection
                // for a configuration change and restart its worker on reconciliation.
                identity.lastUsedAt = nil
                result.append((try? encoder.encode(identity)) ?? Data())
                if let id = identity.keyID, let key = hosts.key(id) {
                    result.append((try? encoder.encode(key)) ?? Data())
                }
            }
        }
        return result
    }

    private func persist(_ selections: [MetricsSelection]) -> Bool {
        do {
            try preferences.save(Self.deduplicated(selections))
            storageError = nil
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    private func applyConfiguration(_ selections: [MetricsSelection]) {
        let normalized = Self.deduplicated(selections)
        configuredSelections = normalized
        let previous = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        let configuredIDs = Set(normalized.map(\.id))
        var nextServers: [ServerMetric] = []

        for selection in normalized {
            guard let host = hosts.host(selection.id) else { continue }
            if let server = previous[selection.id] {
                let enabledChanged = server.selection.enabled != selection.enabled
                let devicesChanged =
                    server.selection.disks != selection.disks
                    || server.selection.interfaces != selection.interfaces
                server.selection = selection
                server.name = host.name
                if enabledChanged || devicesChanged {
                    cancel(server.id)
                    server.isConnecting = false
                    server.authenticationHost = nil
                    server.hostKey = nil
                    server.authenticationPrompt = nil
                    server.hostKeyPrompt = nil
                    server.needsAttention = false
                    if devicesChanged {
                        server.history = []
                        server.point = nil
                    }
                    if !selection.enabled {
                        submissions[server.id] = nil
                        proxySubmissions[server.id] = nil
                        temporaryKeys[server.id] = nil
                        server.journey.hide()
                    }
                }
                nextServers.append(server)
            } else {
                nextServers.append(ServerMetric(selection: selection, name: host.name))
            }
        }

        for server in servers where !nextServers.contains(where: { $0.id == server.id }) {
            cancel(server.id)
            if !configuredIDs.contains(server.id) {
                submissions[server.id] = nil
                proxySubmissions[server.id] = nil
                temporaryKeys[server.id] = nil
                stamps[server.id] = nil
                detailObservers = detailObservers.filter { $0.value != server.id }
            }
        }
        servers = nextServers
        for server in servers { launch(server) }
    }

    private static func deduplicated(_ selections: [MetricsSelection]) -> [MetricsSelection] {
        var seen = Set<UUID>()
        return selections.filter { seen.insert($0.id).inserted }
    }

    private func cancel(_ id: UUID) {
        generations[id] = nil
        workers.removeValue(forKey: id)?.cancel()
        let hadHostKeyAuthorization = pendingHostKeyAuthorizations[id] != nil
        finishHostKeyAuthorization(for: id, decision: .reject)
        let authentication = pendingKeyboardAuthentications.removeValue(forKey: id)
        authentication?.task.cancel()
        if let server = servers.first(where: { $0.id == id }) {
            if hadHostKeyAuthorization {
                server.hostKey = nil
                server.hostKeyHostID = nil
                server.hostKeyPrompt = nil
            }
            if hadHostKeyAuthorization || authentication != nil { server.needsAttention = false }
            server.keyboardAuthentication.cancelAll()
        }
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
        let serverID = server.id
        let clock = clock
        workers[server.id] = Task.detached { [weak self] in
            await self?.run(serverID, token: token, clock: clock)
        }
    }

    private func beginConnectionJourney(for server: ServerMetric, host: Host) {
        server.journey.begin(
            host: host, route: hosts.route(for: host), purpose: .metrics,
            username: submissions[server.id]?[host.id]?.username ?? hosts.identity(for: host)?.username
        )
    }

    private func current(_ serverID: UUID, _ token: UUID) -> Bool {
        !Task.isCancelled && generations[serverID] == token && !stopped && !sleeping
    }

    private nonisolated func run(_ serverID: UUID, token: UUID, clock: MetricsClock) async {
        var delay = 2.0
        while await isCurrent(serverID, token: token) {
            var attempt: RunAttempt
            do {
                guard let next = try await beginRunAttempt(serverID, token: token) else { return }
                attempt = next
            } catch {
                guard await handleRunFailure(error, serverID: serverID, token: token) else { return }
                guard await finishRunCycle(serverID, token: token) == .retry else { return }
                do { try await clock.sleep(delay) } catch { return }
                delay = min(60, delay * 2)
                continue
            }

            let sampler = attempt.sampler
            do {
                guard let preparation = attempt.preparation else { throw CancellationError() }
                attempt.preparation = nil
                let configuration = try await preparation.resolve(
                    trustPolicy: .allowChallenge
                )
                guard await isCurrent(serverID, token: token) else {
                    await sampler.disconnect()
                    return
                }
                try await sampler.connect(
                    SSHConnectionRequest(
                        configuration: configuration,
                        authorizeHostKey: { [weak self] challenge in
                            guard let self else { throw CancellationError() }
                            return await self.authorizeHostKeyFromWorker(
                                serverID, challenge: challenge, token: token
                            )
                        },
                        keyboardInteractive: { [weak self] challenge in
                            guard let self else { throw CancellationError() }
                            return try await self.answerKeyboardInteractiveFromWorker(
                                serverID, challenge: challenge, token: token)
                        }
                    )
                )
                guard await publishConnected(serverID, token: token, hostID: attempt.host.id) else {
                    await sampler.disconnect()
                    return
                }
                var previous: MetricsSample?
                var previousProcesses: MetricsProcessSample?
                var nextFilesystemRefresh = Date.distantPast
                var probeGPU = true
                sampleLoop: while await isCurrent(serverID, token: token) {
                    let began = clock.now()
                    let sample = try await sampler.sample()
                    guard
                        var point = await publishBaseSample(
                            sample, previous: previous, serverID: serverID, token: token)
                    else { break }
                    previous = sample
                    delay = 2
                    if probeGPU {
                        do {
                            let gpu = try await sampler.gpu()
                            guard
                                let updated = await publishGPU(
                                    gpu, point: point, serverID: serverID, token: token)
                            else { break sampleLoop }
                            point = updated
                            let devices = gpu?.devices ?? []
                            probeGPU = !devices.isEmpty
                        } catch {
                            guard await markGPUFailed(serverID, token: token) else { break sampleLoop }
                            // Unknown GPU values create a gap, not a false zero or a repeated stale sample.
                        }
                    }
                    if await observesDetails(serverID, token: token) {
                        if clock.now() >= nextFilesystemRefresh {
                            do {
                                if let filesystems = try await sampler.filesystems() {
                                    guard
                                        await publishFilesystems(
                                            filesystems, serverID: serverID, token: token)
                                    else { break sampleLoop }
                                }
                            } catch {
                                guard await markFilesystemsFailed(serverID, token: token) else {
                                    break sampleLoop
                                }
                            }
                            nextFilesystemRefresh = clock.now().addingTimeInterval(30)
                        }
                        do {
                            if let processes = try await sampler.processes() {
                                guard
                                    await publishProcesses(
                                        processes, previous: previousProcesses,
                                        serverID: serverID, token: token)
                                else { break sampleLoop }
                                previousProcesses = processes
                            }
                        } catch {
                            guard await markProcessesFailed(serverID, token: token) else { break sampleLoop }
                            previousProcesses = nil
                        }
                    } else {
                        previousProcesses = nil
                    }
                    guard await finishSample(point, serverID: serverID, token: token) else { break }
                    try await clock.sleep(min(2, max(0.05, 2 - clock.now().timeIntervalSince(began))))
                }
            } catch {
                guard await handleRunFailure(error, serverID: serverID, token: token) else {
                    await sampler.disconnect()
                    return
                }
            }
            await sampler.disconnect()
            guard await finishRunCycle(serverID, token: token) == .retry else { return }
            do { try await clock.sleep(delay) } catch { return }
            delay = min(60, delay * 2)
        }
    }

    private func beginRunAttempt(_ serverID: UUID, token: UUID) throws -> RunAttempt? {
        guard current(serverID, token), let server = servers.first(where: { $0.id == serverID }) else { return nil }
        guard let host = hosts.host(serverID) else { return nil }
        if server.journey.phase != .connecting {
            beginConnectionJourney(for: server, host: host)
        }
        server.status = String(localized: "Connecting…")
        server.collectionState = .connecting
        server.isConnecting = true
        let route = hosts.route(for: host)
        if let passwordHost = submissions[server.id]?.firstHostRequiringPassword(in: route) {
            throw TermindSSHError.routeHost(
                hostID: passwordHost.id, authentication: true,
                serverChallenge: false, hostKey: false,
                message: TermindSSHError.missingCredential.localizedDescription
            )
        }
        if let passphraseHost = submissions[server.id]?.firstHostRequiringPassphrase(
            in: route, key: hosts.key
        ) {
            throw TermindSSHError.routeHost(
                hostID: passphraseHost.id, authentication: true,
                serverChallenge: false, hostKey: false,
                message: TermindSSHError.keyPassphraseRequired.localizedDescription
            )
        }
        var retained = submissions[server.id] ?? [:]
        var retainedProxies = proxySubmissions[server.id] ?? [:]
        let attemptSubmissions = retained.takeAuthenticationSecrets()
        let attemptProxySubmissions = retainedProxies.takeProxyAuthenticationSecrets()
        submissions[server.id] = retained
        proxySubmissions[server.id] = retainedProxies
        let preparation = try preparation(
            for: host, server: server, submissions: attemptSubmissions,
            proxySubmissions: attemptProxySubmissions
        )
        let sampler = makeSampler()
        samplers[serverID] = sampler
        return RunAttempt(host: host, preparation: preparation, sampler: sampler)
    }

    private func isCurrent(_ serverID: UUID, token: UUID) -> Bool {
        current(serverID, token)
    }

    private func publishConnected(_ serverID: UUID, token: UUID, hostID: UUID) -> Bool {
        guard current(serverID, token), let server = servers.first(where: { $0.id == serverID }) else { return false }
        server.isConnecting = false
        server.journey.receive(.connected(hostID))
        server.status = String(localized: "Connected — collecting metrics…")
        server.collectionState = .collecting
        return true
    }

    private func publishBaseSample(
        _ sample: MetricsSample, previous: MetricsSample?, serverID: UUID, token: UUID
    ) -> MetricsPoint? {
        guard current(serverID, token), let server = servers.first(where: { $0.id == serverID }) else { return nil }
        let point = MetricsCalculation.point(
            previous: previous, current: sample, selection: server.selection, date: clock.now()
        )
        server.disks = sample.disks.map { $0.keys.sorted() } ?? server.disks
        server.interfaces = sample.interfaces.map { $0.keys.sorted() } ?? server.interfaces
        server.status = String(localized: "Live")
        server.collectionState = .live
        if server.journey.phase == .connecting { server.journey.succeed() }
        // Publish base metrics before the optional, bounded GPU command.
        server.point = point
        return point
    }

    private func publishGPU(
        _ gpu: NvidiaSnapshot?, point: MetricsPoint, serverID: UUID, token: UUID
    ) -> MetricsPoint? {
        guard current(serverID, token), let server = servers.first(where: { $0.id == serverID }) else { return nil }
        server.gpuSnapshot = gpu
        server.gpuDate = clock.now()
        let devices = gpu?.devices ?? []
        server.gpuState = devices.isEmpty ? .unavailable : .available
        let ids = Set(devices.map(\.id))
        for index in server.history.indices {
            server.history[index].gpus.removeAll { !ids.contains($0.id) }
        }
        var point = point
        point.gpus = devices
        return point
    }

    private func markGPUFailed(_ serverID: UUID, token: UUID) -> Bool {
        guard current(serverID, token), let server = servers.first(where: { $0.id == serverID }) else { return false }
        server.gpuState = .failed
        return true
    }

    private func observesDetails(_ serverID: UUID, token: UUID) -> Bool {
        current(serverID, token) && detailObservers.values.contains(serverID)
    }

    private func publishFilesystems(_ values: [MetricsFilesystem], serverID: UUID, token: UUID) -> Bool {
        guard current(serverID, token), let server = servers.first(where: { $0.id == serverID }) else { return false }
        server.filesystems = values
        server.filesystemsDate = clock.now()
        server.filesystemsFailed = false
        return true
    }

    private func markFilesystemsFailed(_ serverID: UUID, token: UUID) -> Bool {
        guard current(serverID, token), let server = servers.first(where: { $0.id == serverID }) else { return false }
        server.filesystemsFailed = true
        return true
    }

    private func publishProcesses(
        _ values: MetricsProcessSample, previous: MetricsProcessSample?, serverID: UUID, token: UUID
    ) -> Bool {
        guard current(serverID, token), let server = servers.first(where: { $0.id == serverID }) else { return false }
        server.processes = MetricsProcess.rows(previous: previous, current: values)
        server.processesDate = clock.now()
        server.processesFailed = false
        return true
    }

    private func markProcessesFailed(_ serverID: UUID, token: UUID) -> Bool {
        guard current(serverID, token), let server = servers.first(where: { $0.id == serverID }) else { return false }
        server.processesFailed = true
        return true
    }

    private func finishSample(_ point: MetricsPoint, serverID: UUID, token: UUID) -> Bool {
        guard current(serverID, token), let server = servers.first(where: { $0.id == serverID }) else { return false }
        server.point = point
        server.history.append(point)
        server.history.removeAll { $0.date < clock.now().addingTimeInterval(-300) }
        return true
    }

    private func handleRunFailure(_ error: any Error, serverID: UUID, token: UUID) -> Bool {
        guard current(serverID, token), let server = servers.first(where: { $0.id == serverID }) else { return false }
        server.isConnecting = false
        server.status = error.localizedDescription
        server.collectionState = .failed
        if let ssh = error as? TermindSSHError {
            let targetID = ssh.routeHostID ?? serverID
            if ssh.isLocalAuthenticationRequirement || ssh.shouldRequestAuthentication {
                requestAuthentication(server, hostID: targetID, error: ssh)
            }
        }
        if case MetricsReadError.unsupported = error { server.needsAttention = true }
        if !server.requiresAuthentication { server.journey.fail(error.localizedDescription) }
        return true
    }

    private func finishRunCycle(_ serverID: UUID, token: UUID) -> RunCycleDisposition {
        guard current(serverID, token), let server = servers.first(where: { $0.id == serverID }) else { return .stop }
        if server.needsAttention {
            workers[serverID] = nil
            samplers[serverID] = nil
            return .attention
        }
        return .retry
    }

    private nonisolated func answerKeyboardInteractiveFromWorker(
        _ serverID: UUID, challenge: SSHKeyboardInteractiveChallenge, token: UUID
    ) async throws -> [String] {
        guard await isCurrent(serverID, token: token) else { throw CancellationError() }
        // Informational rounds must complete even when no Metrics detail is visible.
        guard !challenge.prompts.isEmpty else { return [] }
        guard let task = await beginKeyboardAuthentication(serverID, challenge: challenge, token: token) else {
            throw CancellationError()
        }
        do {
            let answers = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard await finishKeyboardAuthentication(serverID, requestID: challenge.id, token: token) else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            return answers
        } catch {
            _ = await finishKeyboardAuthentication(serverID, requestID: challenge.id, token: token)
            throw error
        }
    }

    private func beginKeyboardAuthentication(
        _ serverID: UUID, challenge: SSHKeyboardInteractiveChallenge, token: UUID
    ) -> Task<[String], any Error>? {
        guard current(serverID, token), let server = servers.first(where: { $0.id == serverID }) else { return nil }
        let queue = server.keyboardAuthentication
        // Retain the responder before yielding so retiring this attempt also cancels a not-yet-enqueued request.
        let task = Task { try await queue.request(challenge) }
        pendingKeyboardAuthentications[serverID] = PendingKeyboardAuthentication(id: challenge.id, task: task)
        server.needsAttention = true
        server.isConnecting = false
        server.status = String(localized: "Authentication required")
        server.collectionState = .awaitingAuthentication
        server.journey.waitForAuthentication(at: challenge.hostID)
        return task
    }

    private func finishKeyboardAuthentication(_ serverID: UUID, requestID: UUID, token: UUID) -> Bool {
        guard generations[serverID] == token, pendingKeyboardAuthentications[serverID]?.id == requestID,
            let server = servers.first(where: { $0.id == serverID })
        else { return false }
        pendingKeyboardAuthentications[serverID] = nil
        server.needsAttention = false
        server.isConnecting = true
        server.status = String(localized: "Connecting…")
        server.collectionState = .connecting
        server.journey.resume()
        return true
    }

    private nonisolated func authorizeHostKeyFromWorker(
        _ serverID: UUID, challenge: SSHHostKeyChallenge, token: UUID
    ) async -> SSHHostKeyDecision {
        guard let authorization = await beginHostKeyAuthorization(serverID, challenge: challenge, token: token) else {
            return .reject
        }
        return await withTaskCancellationHandler {
            for await decision in authorization.decisions { return decision }
            return .reject
        } onCancel: {
            Task.detached { [weak self] in
                await self?.cancelHostKeyAuthorization(for: serverID, id: authorization.id)
            }
        }
    }

    private func beginHostKeyAuthorization(
        _ serverID: UUID, challenge: SSHHostKeyChallenge, token: UUID
    ) -> HostKeyAuthorization? {
        guard current(serverID, token), let server = servers.first(where: { $0.id == serverID }) else { return nil }
        finishHostKeyAuthorization(for: serverID, decision: .reject)
        if !challenge.expectedHostKeys.isEmpty {
            hosts.markKnownHostMismatched(
                hostname: challenge.observation.hostname,
                port: challenge.observation.port
            )
        }
        server.hostKey = challenge.observation
        server.hostKeyHostID = challenge.hostID
        server.hostKeyPrompt = SSHHostKeyPrompt(
            observation: challenge.observation,
            kind: challenge.expectedHostKeys.isEmpty
                ? .firstUse
                : .additionalKey(trustedKeyCount: challenge.expectedHostKeys.count)
        )
        server.status = String(localized: "Server Identity Verification Required")
        server.needsAttention = true
        server.journey.waitForHostKey(
            at: challenge.hostID,
            fingerprint: challenge.observation.fingerprint
        )
        let authorizationID = UUID()
        let decisions = AsyncStream<SSHHostKeyDecision> { continuation in
            pendingHostKeyAuthorizations[serverID] = PendingHostKeyAuthorization(
                id: authorizationID, continuation: continuation
            )
        }
        return HostKeyAuthorization(id: authorizationID, decisions: decisions)
    }

    private func cancelHostKeyAuthorization(for serverID: UUID, id: UUID) {
        guard pendingHostKeyAuthorizations[serverID]?.id == id else { return }
        finishHostKeyAuthorization(for: serverID, decision: .reject)
    }

    private func finishHostKeyAuthorization(
        for serverID: UUID, decision: SSHHostKeyDecision
    ) {
        guard let pending = pendingHostKeyAuthorizations.removeValue(forKey: serverID) else { return }
        pending.continuation.yield(decision)
        pending.continuation.finish()
    }
}

#if DEBUG
    private final class ScreenshotMetricsPreferences: MetricsConfigurationStoring {
        func load() -> [MetricsSelection] { [] }
        func save(_ selections: [MetricsSelection]) {}
    }
#endif
