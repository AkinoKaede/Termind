@preconcurrency import ActivityKit
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class MobileLiveActivityController {
    private(set) var error: String?
    private var activity: Activity<WorkspaceActivityAttributes>?
    private var updates: Task<Void, Never>?
    private let enabled: Bool
    private var focusedWorkspaceID: UUID?

    init(enabled: Bool = true) {
        self.enabled = enabled
        if enabled {
            let restored = Activity<WorkspaceActivityAttributes>.activities
            activity = restored.first
            updates = Task {
                for duplicate in restored.dropFirst() {
                    await duplicate.end(nil, dismissalPolicy: .immediate)
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
                if let activity { await activity.end(nil, dismissalPolicy: .immediate) }
                activity = nil
                return
            }
            let content = ActivityContent(state: state, staleDate: Date.now.addingTimeInterval(60))
            if let activity, activity.activityState == .active || activity.activityState == .stale {
                await activity.update(content)
                return
            }
            // Updates do not restart a dismissed activity. Requests require the foreground.
            guard mayStart, UIApplication.shared.applicationState == .active,
                ActivityAuthorizationInfo().areActivitiesEnabled
            else { return }
            do {
                activity = try Activity.request(
                    attributes: WorkspaceActivityAttributes(), content: content, pushType: nil)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
