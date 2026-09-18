@preconcurrency import ActivityKit
import Foundation
import UIKit

@MainActor
protocol MobileWorkspaceActivity {
    var id: String { get }
    var state: ActivityState { get }
    var focusedWorkspaceID: UUID? { get }
    func update(_ state: WorkspaceActivityAttributes.ContentState) async
    func end() async
}

@MainActor
struct MobileLiveActivityServices {
    var activities: () -> [any MobileWorkspaceActivity]
    var canStart: () -> Bool
    var request: (WorkspaceActivityAttributes.ContentState) throws -> any MobileWorkspaceActivity

    static var live: Self {
        Self(
            activities: { Activity<WorkspaceActivityAttributes>.activities.map(WorkspaceActivity.init) },
            canStart: {
                UIApplication.shared.applicationState == .active && ActivityAuthorizationInfo().areActivitiesEnabled
            },
            request: { state in
                WorkspaceActivity(
                    activity: try Activity.request(
                        attributes: WorkspaceActivityAttributes(),
                        content: ActivityContent(state: state, staleDate: Date.now.addingTimeInterval(60)),
                        pushType: nil))
            })
    }
}

@MainActor
private struct WorkspaceActivity: MobileWorkspaceActivity {
    let activity: Activity<WorkspaceActivityAttributes>
    var id: String { activity.id }
    var state: ActivityState { activity.activityState }
    var focusedWorkspaceID: UUID? { activity.content.state.focusedWorkspaceID }

    func update(_ state: WorkspaceActivityAttributes.ContentState) async {
        await activity.update(ActivityContent(state: state, staleDate: Date.now.addingTimeInterval(60)))
    }

    func end() async {
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}
