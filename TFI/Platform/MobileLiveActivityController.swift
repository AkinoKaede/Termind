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
    private var pendingState: WorkspaceActivityAttributes.ContentState?

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

    /// Serialize system calls, but coalesce queued changes so closed workspaces are never recreated.
    func start(_ sessions: [WorkspaceActivityAttributes.Session]) { schedule(sessions, mayStart: true) }
    func update(_ sessions: [WorkspaceActivityAttributes.Session]) { schedule(sessions, mayStart: false) }

    private func schedule(_ sessions: [WorkspaceActivityAttributes.Session], mayStart: Bool) {
        guard enabled else { return }
        pendingState = WorkspaceActivityAttributes.ContentState.snapshot(
            sessions, focusedID: focusedWorkspaceID)
        if sessions.isEmpty {
            pendingStart = false
        } else if mayStart {
            pendingStart = true
        }
        guard updates == nil else { return }
        updates = Task { [weak self] in
            guard let self else { return }
            while let state = pendingState {
                pendingState = nil
                await reconcile(state)
            }
            updates = nil
        }
    }

    private func reconcile(_ state: WorkspaceActivityAttributes.ContentState) async {
        // ActivityKit can expose old cards after startup. The cached handle is not the full inventory.
        var activities = services.activities()
        if let activity, !activities.contains(where: { $0.id == activity.id }) { activities.append(activity) }
        let usable = activities.filter { $0.state == .active || $0.state == .stale }
        let retained =
            state.workspaceCount > 0
            ? usable.first(where: { $0.id == activity?.id }) ?? usable.first : nil
        activity = retained
        if retained != nil { pendingStart = false }
        for other in activities where other.id != retained?.id { await other.end() }

        // An open/close may have arrived while dismissal was suspended. Publish only the newest list.
        guard pendingState == nil, state.workspaceCount > 0 else { return }
        if let activity {
            if activity.state == .active || activity.state == .stale {
                await activity.update(state)
                return
            }
            await activity.end()
            self.activity = nil
        }
        // An explicit open may arrive before activation. Retain its intent until a foreground update.
        // Once consumed, ordinary updates cannot resurrect a user-dismissed activity.
        guard pendingState == nil, pendingStart, services.canStart() else { return }
        pendingStart = false
        do {
            activity = try services.request(state)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
