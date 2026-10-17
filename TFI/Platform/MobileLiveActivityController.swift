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

    init(enabled: Bool = true, services: MobileLiveActivityServices = .live) {
        self.enabled = enabled
        self.services = services
        if enabled {
            activity = services.activities().first { $0.state == .active || $0.state == .stale }
            focusedWorkspaceID = activity?.focusedWorkspaceID
        }
    }

    func focus(_ id: UUID, in sessions: [WorkspaceActivityAttributes.Session]) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        focusedWorkspaceID = id
        update(sessions)
    }

    /// Reconcile system cards only after the local snapshot has loaded successfully.
    func restore(_ sessions: [WorkspaceActivityAttributes.Session]) {
        schedule(sessions, mayStart: false, restoring: true)
    }

    /// All starts, updates and ends share a serial queue, including close-last/open-new races.
    func start(_ sessions: [WorkspaceActivityAttributes.Session]) { schedule(sessions, mayStart: true) }
    func update(_ sessions: [WorkspaceActivityAttributes.Session]) { schedule(sessions, mayStart: false) }

    private func schedule(
        _ sessions: [WorkspaceActivityAttributes.Session], mayStart: Bool, restoring: Bool = false
    ) {
        guard enabled else { return }
        let state = WorkspaceActivityAttributes.ContentState.snapshot(
            sessions, focusedID: focusedWorkspaceID)
        let previous = updates
        updates = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if restoring {
                for old in services.activities() where old.id != activity?.id { await old.end() }
            }
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
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
