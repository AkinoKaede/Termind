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

    init(enabled: Bool = true, services: MobileLiveActivityServices = .live) {
        self.enabled = enabled
        self.services = services
        if enabled {
            let restored = services.activities()
            activity = restored.first { $0.state == .active || $0.state == .stale }
            focusedWorkspaceID = activity?.focusedWorkspaceID
            let retainedID = activity?.id
            updates = Task {
                for duplicate in restored where duplicate.id != retainedID {
                    await duplicate.end()
                }
            }
        }
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
        let state = WorkspaceActivityAttributes.ContentState.snapshot(
            sessions, focusedID: focusedWorkspaceID)
        let previous = updates
        updates = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard state.workspaceCount > 0 else {
                if let activity { await activity.end() }
                activity = nil
                return
            }
            if let activity, activity.state == .active || activity.state == .stale {
                await activity.update(state)
                return
            }
            // Updates do not restart a dismissed activity. Requests require the foreground.
            guard mayStart, services.canStart() else { return }
            do {
                activity = try services.request(state)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
