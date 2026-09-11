@preconcurrency import ActivityKit
import Foundation
import Observation
import TermindPresentation
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

    func focus(_ id: UUID, in workspaces: [MobileWorkspace]) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        focusedWorkspaceID = id
        update(workspaces)
    }

    /// All starts, updates and ends share a serial queue, including close-last/open-new races.
    func start(_ workspaces: [MobileWorkspace]) { schedule(workspaces, mayStart: true) }
    func update(_ workspaces: [MobileWorkspace]) { schedule(workspaces, mayStart: false) }

    private func schedule(_ workspaces: [MobileWorkspace], mayStart: Bool) {
        guard enabled else { return }
        let state = WorkspaceActivityAttributes.ContentState.snapshot(
            workspaces.map {
                .init(
                    id: $0.id, title: $0.descriptor.title, kind: $0.descriptor.kind.rawValue, connected: $0.connected,
                    iconAsset: LinuxDistributionIconCatalog.entry(for: $0.detectedDistribution)?.asset)
            }, focusedID: focusedWorkspaceID)
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
