import Foundation
import TermindDomain

public nonisolated enum SFTPWorkSource: Hashable, Sendable {
    case workspace(UUID)
    case agentRun(UUID)
    case batch(UUID)
}

public actor SFTPConcurrencyPermit {
    public nonisolated let schedulingMode: SSHChannelSchedulingMode
    private var releaseAction: (@Sendable () async -> Void)?

    fileprivate init(
        schedulingMode: SSHChannelSchedulingMode,
        release: @escaping @Sendable () async -> Void
    ) {
        self.schedulingMode = schedulingMode
        releaseAction = release
    }

    public func release() async {
        let action = releaseAction
        releaseAction = nil
        await action?()
    }
}

/// Process-wide admission for SFTP data work.
///
/// Capacity is counted in logical file operations. A remote copy therefore
/// consumes one global slot and one slot on each distinct endpoint Host even
/// though its implementation may hold two SFTP leases.
public actor SFTPConcurrencyScheduler {
    private struct Request {
        var id: UUID
        var anchorHostID: UUID
        var hostIDs: Set<UUID>
        var source: SFTPWorkSource
        var byteCount: Int64?
        var exclusiveResourceIDs: Set<UUID>
        var continuation: CheckedContinuation<SFTPConcurrencyPermit, any Error>
    }

    private struct ActiveRequest {
        var hostIDs: Set<UUID>
        var exclusiveResourceIDs: Set<UUID>
    }

    private var preferences: SFTPPreferences
    private var requests: [UUID: Request] = [:]
    private var queues: [UUID: [SFTPWorkSource: [UUID]]] = [:]
    private var hostOrder: [UUID] = []
    private var sourceOrder: [UUID: [SFTPWorkSource]] = [:]
    private var lastGrantedHost: UUID?
    private var lastGrantedSource: [UUID: SFTPWorkSource] = [:]
    private var active: [UUID: ActiveRequest] = [:]
    private var activePerHost: [UUID: Int] = [:]
    private var activeExclusiveResources: Set<UUID> = []

    public init(preferences: SFTPPreferences = SFTPPreferences()) {
        self.preferences = preferences.normalized
    }

    public func updatePreferences(_ value: SFTPPreferences) {
        preferences = value.normalized
        drain()
    }

    public func acquire(
        anchorHostID: UUID,
        hostIDs: Set<UUID>,
        source: SFTPWorkSource,
        byteCount: Int64?,
        exclusiveResourceIDs: Set<UUID> = []
    ) async throws -> SFTPConcurrencyPermit {
        try Task.checkCancellation()
        let id = UUID()
        let normalizedHosts = hostIDs.union([anchorHostID])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let request = Request(
                    id: id,
                    anchorHostID: anchorHostID,
                    hostIDs: normalizedHosts,
                    source: source,
                    byteCount: byteCount,
                    exclusiveResourceIDs: exclusiveResourceIDs,
                    continuation: continuation
                )
                requests[id] = request
                if queues[anchorHostID] == nil {
                    queues[anchorHostID] = [:]
                    hostOrder.append(anchorHostID)
                }
                if queues[anchorHostID]?[source] == nil {
                    queues[anchorHostID]?[source] = []
                    sourceOrder[anchorHostID, default: []].append(source)
                }
                queues[anchorHostID]?[source, default: []].append(id)
                drain()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    public var activeCount: Int { active.count }
    public var queuedCount: Int { requests.count }

    public func activeCount(for hostID: UUID) -> Int {
        activePerHost[hostID, default: 0]
    }

    private func cancel(_ id: UUID) {
        guard let request = requests.removeValue(forKey: id) else { return }
        removeQueuedID(id, request: request)
        request.continuation.resume(throwing: CancellationError())
        pruneEmptyQueues()
        drain()
    }

    private func release(_ id: UUID) {
        guard let request = active.removeValue(forKey: id) else { return }
        for hostID in request.hostIDs {
            let remaining = max(0, activePerHost[hostID, default: 1] - 1)
            activePerHost[hostID] = remaining == 0 ? nil : remaining
        }
        activeExclusiveResources.subtract(request.exclusiveResourceIDs)
        drain()
    }

    private func drain() {
        while active.count < preferences.globalLimit, let request = nextEligibleRequest() {
            requests[request.id] = nil
            removeQueuedID(request.id, request: request)
            let permitID = UUID()
            active[permitID] = ActiveRequest(
                hostIDs: request.hostIDs,
                exclusiveResourceIDs: request.exclusiveResourceIDs)
            for hostID in request.hostIDs { activePerHost[hostID, default: 0] += 1 }
            activeExclusiveResources.formUnion(request.exclusiveResourceIDs)
            lastGrantedHost = request.anchorHostID
            lastGrantedSource[request.anchorHostID] = request.source
            let mode = schedulingMode(byteCount: request.byteCount)
            request.continuation.resume(
                returning: SFTPConcurrencyPermit(schedulingMode: mode) { [weak self] in
                    await self?.release(permitID)
                })
        }
        pruneEmptyQueues()
    }

    private func nextEligibleRequest() -> Request? {
        for hostID in rotated(hostOrder, after: lastGrantedHost) {
            guard let hostQueues = queues[hostID] else { continue }
            let sources = sourceOrder[hostID] ?? []
            for source in rotated(sources, after: lastGrantedSource[hostID]) {
                guard let id = hostQueues[source]?.first, let request = requests[id] else { continue }
                guard request.hostIDs.allSatisfy({ activePerHost[$0, default: 0] < preferences.perHostLimit })
                else { continue }
                guard request.exclusiveResourceIDs.isDisjoint(with: activeExclusiveResources) else { continue }
                return request
            }
        }
        return nil
    }

    private func schedulingMode(byteCount: Int64?) -> SSHChannelSchedulingMode {
        switch preferences.strategy {
        case .channelsOnly:
            .channelsOnly
        case .connectionsPreferred:
            .connectionsPreferred
        case .smart:
            if let byteCount, byteCount > SFTPConcurrencyStrategy.smartConnectionThreshold {
                .connectionsPreferred
            } else {
                .channelsOnly
            }
        }
    }

    private func removeQueuedID(_ id: UUID, request: Request) {
        guard var values = queues[request.anchorHostID]?[request.source] else { return }
        values.removeAll { $0 == id }
        queues[request.anchorHostID]?[request.source] = values
    }

    private func pruneEmptyQueues() {
        for hostID in hostOrder {
            guard var hostQueues = queues[hostID] else { continue }
            for source in sourceOrder[hostID] ?? [] where hostQueues[source]?.isEmpty != false {
                hostQueues[source] = nil
                sourceOrder[hostID]?.removeAll { $0 == source }
            }
            if hostQueues.isEmpty {
                queues[hostID] = nil
                sourceOrder[hostID] = nil
                hostOrder.removeAll { $0 == hostID }
            } else {
                queues[hostID] = hostQueues
            }
        }
        let activeHosts = Set(active.values.flatMap(\.hostIDs))
        for hostID in Array(lastGrantedSource.keys)
        where queues[hostID] == nil && !activeHosts.contains(hostID) {
            lastGrantedSource[hostID] = nil
        }
        if let lastGrantedHost, queues[lastGrantedHost] == nil, !activeHosts.contains(lastGrantedHost) {
            self.lastGrantedHost = nil
        }
    }

    private func rotated<Value: Equatable>(_ values: [Value], after last: Value?) -> [Value] {
        guard !values.isEmpty, let last, let index = values.firstIndex(of: last) else { return values }
        let split = values.index(after: index)
        return Array(values[split...]) + Array(values[..<split])
    }
}
