import Darwin
import Foundation
import Logging
import TermindApplication
import TermindDomain

/// A host-scoped group of physical SSH connections. Only local and dynamic rules fan out.
actor SSHForwardingConnectionPool: SSHForwardingConnectionProtocol {
    private final class Slot: @unchecked Sendable {
        let id: UUID
        let connection: SSHForwardingConnection
        var rules: Set<PortForwardingRule.ID> = []

        init(id: UUID, connection: SSHForwardingConnection) {
            self.id = id
            self.connection = connection
        }
    }

    private struct RuleRegistration: Sendable {
        let rule: PortForwardingRule
        let generation: UUID
    }

    private let maximumConnections: Int
    private let connectionHandler: SSHForwardingConnection.ConnectionHandler
    private let failureHandler: SSHForwardingConnection.FailureHandler
    private let logger: Logger
    private let listeners: SSHForwardingLocalListeners
    private var slots: [UUID: Slot] = [:]
    private var primaryID: UUID?
    private var registrations: [PortForwardingRule.ID: RuleRegistration] = [:]
    private var counts: [UUID: [PortForwardingRule.ID: Int]] = [:]
    private var additionalRequest: SSHAdditionalConnectionRequestResolver?
    private var opening: [UUID: Slot] = [:]
    private var installing: [UUID: Slot] = [:]
    private var retryTask: Task<Void, Never>?
    private var stabilityTasks: [UUID: Task<Void, Never>] = [:]
    private var retryAttempt = 0
    private var roundRobin = 0
    private var disconnecting = false

    init(
        maximumConnections: Int,
        connectionHandler: @escaping SSHForwardingConnection.ConnectionHandler,
        failureHandler: @escaping SSHForwardingConnection.FailureHandler,
        logger: Logger = ApplicationLogger.disabled("termind.port-forwarding-pool")
    ) {
        self.maximumConnections = min(max(maximumConnections, 2), Host.portForwardingMaxConnectionsRange.upperBound)
        self.connectionHandler = connectionHandler
        self.failureHandler = failureHandler
        self.logger = logger
        listeners = SSHForwardingLocalListeners { _, _, descriptor in
            Darwin.close(descriptor)
        }
        listeners.setHandler { [weak self] ruleID, generation, descriptor in
            guard let self else {
                Darwin.close(descriptor)
                return
            }
            Task { await self.assign(descriptor, ruleID: ruleID, generation: generation) }
        }
    }

    func connect(_ request: SSHConnectionRequest, progress: SSHRouteProgressHandler?) async throws {
        await disconnect()
        disconnecting = false
        let id = UUID()
        let slot = makeSlot(id: id)
        slots[id] = slot
        primaryID = id
        do {
            try await slot.connection.connect(request, progress: progress)
        } catch {
            slots[id] = nil
            primaryID = nil
            throw error
        }
    }

    func configureAdditionalConnections(_ resolver: @escaping SSHAdditionalConnectionRequestResolver) async {
        additionalRequest = resolver
        fillPool()
    }

    func connectionPoolStatus() async -> SSHForwardingPoolStatus {
        SSHForwardingPoolStatus(connected: slots.count, target: desiredConnections)
    }

    func flowDistribution(for ruleID: PortForwardingRule.ID) async -> [Int] {
        slots.keys.sorted { $0.uuidString < $1.uuidString }.map { counts[$0]?[ruleID] ?? 0 }
    }

    func start(_ rule: PortForwardingRule, generation: UUID) async throws {
        guard let primary = primarySlot else { throw TermindSSHError.disconnected }
        registrations[rule.id] = RuleRegistration(rule: rule, generation: generation)
        do {
            if rule.kind == .remote {
                try await primary.connection.start(rule, generation: generation)
                primary.rules.insert(rule.id)
            } else {
                for slot in slots.values {
                    try await slot.connection.registerShared(rule, generation: generation)
                    slot.rules.insert(rule.id)
                }
                try await listeners.start(rule, generation: generation)
                fillPool()
            }
        } catch {
            registrations[rule.id] = nil
            for slot in slots.values where slot.rules.remove(rule.id) != nil {
                await slot.connection.stop(rule.id)
            }
            await listeners.stop(rule.id)
            throw error
        }
    }

    func stop(_ id: PortForwardingRule.ID) async {
        let registration = registrations.removeValue(forKey: id)
        if registration?.rule.kind != .remote { await listeners.stop(id) }
        for slot in slots.values where slot.rules.remove(id) != nil {
            await slot.connection.stop(id)
        }
        for slotID in counts.keys { counts[slotID]?[id] = nil }
        report(id, generation: registration?.generation)
        if !needsPool { await retireAuxiliaries() }
    }

    func disconnect() async {
        disconnecting = true
        retryTask?.cancel()
        retryTask = nil
        for task in stabilityTasks.values { task.cancel() }
        stabilityTasks.removeAll()
        let pending = Array(opening.values) + Array(installing.values)
        opening.removeAll()
        installing.removeAll()
        await listeners.disconnect()
        let active = Array(slots.values)
        slots.removeAll()
        primaryID = nil
        registrations.removeAll()
        counts.removeAll()
        additionalRequest = nil
        await withTaskGroup(of: Void.self) { group in
            for slot in active + pending { group.addTask { await slot.connection.disconnect() } }
        }
    }

    private var primarySlot: Slot? { primaryID.flatMap { slots[$0] } }
    private var needsPool: Bool { registrations.values.contains { $0.rule.kind != .remote } }
    private var desiredConnections: Int { needsPool ? maximumConnections : 1 }

    private func makeSlot(id: UUID) -> Slot {
        let connection = SSHForwardingConnection(
            connectionHandler: { [weak self] ruleID, generation, count in
                Task { await self?.receivedCount(count, ruleID: ruleID, generation: generation, slotID: id) }
            },
            failureHandler: { [weak self] message in
                Task { await self?.failed(slotID: id, message: message) }
            },
            logger: logger)
        return Slot(id: id, connection: connection)
    }

    private func fillPool() {
        guard !disconnecting, needsPool, additionalRequest != nil else { return }
        let missing = desiredConnections - slots.count - opening.count - installing.count
        guard missing > 0 else { return }
        for _ in 0..<min(missing, max(0, 4 - opening.count - installing.count)) {
            let id = UUID()
            let slot = makeSlot(id: id)
            opening[id] = slot
            let resolver = additionalRequest!
            Task { [weak self] in
                do {
                    let request = try await resolver()
                    try await slot.connection.connect(request, progress: nil)
                    await self?.opened(slot)
                } catch {
                    await self?.openFailed(id: id, error: error)
                    await slot.connection.disconnect()
                }
            }
        }
    }

    private func opened(_ slot: Slot) async {
        guard opening.removeValue(forKey: slot.id) != nil, !disconnecting,
            slots.count + installing.count < desiredConnections
        else {
            await slot.connection.disconnect()
            return
        }
        installing[slot.id] = slot
        do {
            for registration in registrations.values where registration.rule.kind != .remote {
                try await slot.connection.registerShared(registration.rule, generation: registration.generation)
                slot.rules.insert(registration.rule.id)
            }
            guard installing.removeValue(forKey: slot.id) != nil, !disconnecting,
                slots.count < desiredConnections
            else {
                await slot.connection.disconnect()
                return
            }
            slots[slot.id] = slot
            stabilityTasks[slot.id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.becameStable(slot.id)
            }
            publishPoolCounts()
            fillPool()
        } catch {
            let wasInstalling = installing.removeValue(forKey: slot.id) != nil
            await slot.connection.disconnect()
            if wasInstalling { scheduleRetry(for: error) }
        }
    }

    private func openFailed(id: UUID, error: any Error) {
        guard opening.removeValue(forKey: id) != nil, !disconnecting else { return }
        scheduleRetry(for: error)
    }

    private func scheduleRetry(for error: any Error) {
        guard !Self.requiresManualRetry(error), retryTask == nil, needsPool else { return }
        let delays = [1, 2, 5, 10, 30]
        let delay = delays[min(retryAttempt, delays.count - 1)]
        retryAttempt += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.retryReady()
        }
    }

    private func retryReady() {
        retryTask = nil
        fillPool()
    }

    private func becameStable(_ id: UUID) {
        guard slots[id] != nil else { return }
        stabilityTasks[id] = nil
        retryAttempt = 0
    }

    private func failed(slotID: UUID, message: String) async {
        guard !disconnecting else { return }
        if opening.removeValue(forKey: slotID) != nil || installing.removeValue(forKey: slotID) != nil {
            scheduleRetry(for: TermindSSHError.disconnected)
            return
        }
        let wasPrimary = primaryID == slotID
        stabilityTasks.removeValue(forKey: slotID)?.cancel()
        counts[slotID] = nil
        slots[slotID] = nil
        publishPoolCounts()
        if wasPrimary, let promoted = slots.values.first {
            primaryID = promoted.id
            do {
                for registration in registrations.values where registration.rule.kind == .remote {
                    try await promoted.connection.start(registration.rule, generation: registration.generation)
                    promoted.rules.insert(registration.rule.id)
                }
                fillPool()
            } catch {
                failureHandler(error.localizedDescription)
            }
        } else if wasPrimary {
            primaryID = nil
            failureHandler(message)
        } else {
            scheduleRetry(for: TermindSSHError.disconnected)
        }
    }

    private func retireAuxiliaries() async {
        retryTask?.cancel()
        retryTask = nil
        let pending = Array(opening.values) + Array(installing.values)
        opening.removeAll()
        installing.removeAll()
        let primaryID = self.primaryID
        let auxiliaries = slots.values.filter { $0.id != primaryID }
        for slot in auxiliaries {
            slots[slot.id] = nil
            counts[slot.id] = nil
            stabilityTasks.removeValue(forKey: slot.id)?.cancel()
        }
        await withTaskGroup(of: Void.self) { group in
            for slot in auxiliaries + pending { group.addTask { await slot.connection.disconnect() } }
        }
        publishPoolCounts()
    }

    private func assign(_ descriptor: Int32, ruleID: UUID, generation: UUID) async {
        guard let registration = registrations[ruleID], registration.generation == generation else {
            Darwin.close(descriptor)
            return
        }
        let eligible = slots.values.filter { $0.rules.contains(ruleID) }
        guard !eligible.isEmpty else {
            Darwin.close(descriptor)
            return
        }
        let minimum = eligible.map { counts[$0.id]?[ruleID] ?? 0 }.min() ?? 0
        let candidates = eligible.filter { counts[$0.id]?[ruleID] ?? 0 == minimum }.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        let slot = candidates[roundRobin % candidates.count]
        roundRobin &+= 1
        guard await slot.connection.acceptShared(descriptor, ruleID: ruleID, generation: generation) else {
            Darwin.close(descriptor)
            return
        }
    }

    private func receivedCount(_ count: Int, ruleID: UUID, generation: UUID, slotID: UUID) {
        guard registrations[ruleID]?.generation == generation, slots[slotID] != nil else { return }
        counts[slotID, default: [:]][ruleID] = count
        report(ruleID, generation: generation)
    }

    private func report(_ ruleID: UUID, generation: UUID?) {
        guard let generation else { return }
        let total = counts.values.reduce(0) { $0 + ($1[ruleID] ?? 0) }
        connectionHandler(ruleID, generation, total)
    }

    private func publishPoolCounts() {
        for registration in registrations.values {
            report(registration.rule.id, generation: registration.generation)
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
}

private nonisolated final class SSHForwardingLocalListeners: @unchecked Sendable {
    typealias Handler = @Sendable (PortForwardingRule.ID, UUID, Int32) -> Void

    private final class Entry: @unchecked Sendable {
        let generation: UUID
        let socket: Int32
        var events: SSHSocketEvents?

        init(generation: UUID, socket: Int32) {
            self.generation = generation
            self.socket = socket
        }
    }

    private let queue = DispatchQueue(label: "com.akinokaede.termind.ssh.forwarding-listeners")
    private var entries: [PortForwardingRule.ID: Entry] = [:]
    private var handler: Handler

    init(handler: @escaping Handler) { self.handler = handler }

    func setHandler(_ handler: @escaping Handler) {
        queue.sync { self.handler = handler }
    }

    func start(_ rule: PortForwardingRule, generation: UUID) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if let current = entries[rule.id] {
                        guard current.generation == generation else { throw CancellationError() }
                        continuation.resume()
                        return
                    }
                    let socket = try makeListener(host: rule.bindHost, port: rule.bindPort)
                    let entry = Entry(generation: generation, socket: socket)
                    entry.events = SSHSocketEvents(socket: socket, queue: queue) { [weak self, weak entry] in
                        guard let self, let entry else { return }
                        self.accept(ruleID: rule.id, entry: entry)
                    }
                    entries[rule.id] = entry
                    entry.events?.update(read: true, write: false)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop(_ id: PortForwardingRule.ID) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let entry = entries.removeValue(forKey: id) else {
                    continuation.resume()
                    return
                }
                if let events = entry.events {
                    events.cancel {
                        Darwin.close(entry.socket)
                        continuation.resume()
                    }
                } else {
                    Darwin.close(entry.socket)
                    continuation.resume()
                }
            }
        }
    }

    func disconnect() async {
        let ids = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Array(self.entries.keys)) }
        }
        for id in ids { await stop(id) }
    }

    private func accept(ruleID: UUID, entry: Entry) {
        guard entries[ruleID] === entry else { return }
        for _ in 0..<32 {
            let descriptor = Darwin.accept(entry.socket, nil, nil)
            guard descriptor >= 0 else { break }
            handler(ruleID, entry.generation, descriptor)
        }
    }

    private func makeListener(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_PASSIVE
        var result: UnsafeMutablePointer<addrinfo>?
        let resolved = getaddrinfo(host, String(port), &hints, &result)
        guard resolved == 0, let first = result else {
            throw TermindSSHError.socket(String(cString: gai_strerror(resolved)))
        }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor?.pointee {
            let candidate = Darwin.socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if candidate >= 0 {
                var yes: Int32 = 1
                setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                if setsockopt(candidate, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0,
                    Darwin.bind(candidate, info.ai_addr, info.ai_addrlen) == 0,
                    Darwin.listen(candidate, 128) == 0
                {
                    let flags = fcntl(candidate, F_GETFL, 0)
                    if flags >= 0 { _ = fcntl(candidate, F_SETFL, flags | O_NONBLOCK) }
                    return candidate
                }
                Darwin.close(candidate)
            }
            cursor = info.ai_next
        }
        throw TermindSSHError.socket(String(cString: strerror(errno)))
    }
}
