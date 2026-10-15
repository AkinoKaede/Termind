@preconcurrency import ActivityKit
import Foundation
import Observation

@MainActor
@Observable
final class MobileLiveActivityController {
    private(set) var error: String?
    private var activity: (any MobileWorkspaceActivity)?
    private var updates: Task<Void, Never>?
    private let enabled: Bool
    private let services: MobileLiveActivityServices
    private var focusedWorkspaceID: UUID?
    private var pendingStart = false
    private var retainedSessions: [WorkspaceActivityAttributes.Session] = []
    private var removedWorkspaceIDs: Set<UUID> = []

    init(enabled: Bool = true, services: MobileLiveActivityServices = .live) {
        self.enabled = enabled
        self.services = services
        if enabled {
            let restored = services.activities()
            activity = restored.first { $0.state == .active || $0.state == .stale }
            focusedWorkspaceID = activity?.focusedWorkspaceID
            retainedSessions = (activity?.contentState?.sessions ?? []).compactMap { session in
                guard session.recovery?.version == 1 else { return nil }
                var disconnected = session
                disconnected.connected = false
                return disconnected
            }
            let retainedID = activity?.id
            updates = Task {
                for duplicate in restored where duplicate.id != retainedID {
                    await duplicate.end()
                }
            }
        }
    }

    func recovery(for id: UUID) -> WorkspaceActivityAttributes.Recovery? {
        guard !removedWorkspaceIDs.contains(id) else { return nil }
        guard activity?.state == .active || activity?.state == .stale else { return nil }
        return retainedSessions.first(where: { $0.id == id })?.recovery
            ?? activity?.contentState?.sessions.first(where: { $0.id == id })?.recovery
    }

    func remove(_ id: UUID) {
        // ActivityKit updates are asynchronous; never recover from its stale content after an explicit close.
        removedWorkspaceIDs.insert(id)
        retainedSessions.removeAll { $0.id == id }
    }

    func focus(_ id: UUID, in sessions: [WorkspaceActivityAttributes.Session]) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        focusedWorkspaceID = id
        update(sessions)
    }

    /// All starts, updates and ends share a serial queue, including close-last/open-new races.
    func start(_ sessions: [WorkspaceActivityAttributes.Session]) { schedule(sessions, mayStart: true) }
    func update(_ sessions: [WorkspaceActivityAttributes.Session]) { schedule(sessions, mayStart: false) }

    private func schedule(_ sessions: [WorkspaceActivityAttributes.Session], mayStart: Bool) {
        guard enabled else { return }
        let liveIDs = Set(sessions.map(\.id))
        retainedSessions.removeAll { liveIDs.contains($0.id) }
        let state = WorkspaceActivityAttributes.ContentState.snapshot(
            sessions + retainedSessions, focusedID: focusedWorkspaceID)
        let previous = updates
        updates = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if mayStart { pendingStart = true }
            guard state.workspaceCount > 0 else {
                pendingStart = false
                if let activity { await activity.end() }
                activity = nil
                return
            }
            if let activity, activity.state == .active || activity.state == .stale {
                pendingStart = false
                await activity.update(state)
                return
            }
            // An explicit open may arrive before activation. Retain its intent until a foreground update.
            // Once consumed, ordinary updates cannot resurrect a user-dismissed activity.
            guard pendingStart, services.canStart() else { return }
            pendingStart = false
            do {
                activity = try services.request(state)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
