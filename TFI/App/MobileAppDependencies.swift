import Foundation
import SwiftData
import TermindApplication

@MainActor
struct MobileAppDependencies {
    var hosts: (any HostRepository)?
    var inMemory: Bool
    var defaults: UserDefaults?
    var forwardingDefaults: UserDefaults?
    var background: any MobileBackgroundTaskManaging
    var workspaceConnections: MobileWorkspaceConnectionServices
    var metrics: MobileMetricsServices
    var appReview: AppReviewController
    var container: ModelContainer? = nil
    var workspaceStore: MobileWorkspaceStore? = nil
    var liveActivities: MobileLiveActivityController? = nil

    static func live() -> MobileAppDependencies {
        MobileAppDependencies(
            hosts: nil,
            inMemory: false,
            defaults: .standard,
            forwardingDefaults: .standard,
            background: MobileBackgroundController(),
            workspaceConnections: .live,
            metrics: .live,
            appReview: .live()
        )
    }

    static func testing(
        hosts: (any HostRepository)? = nil,
        defaults: UserDefaults? = nil,
        forwardingDefaults: UserDefaults? = nil,
        background: any MobileBackgroundTaskManaging = MobileBackgroundController(),
        workspaceConnections: MobileWorkspaceConnectionServices = .live,
        metrics: MobileMetricsServices = .testing,
        appReview: AppReviewController = AppReviewController()
    ) -> MobileAppDependencies {
        MobileAppDependencies(
            hosts: hosts,
            inMemory: true,
            defaults: defaults,
            forwardingDefaults: forwardingDefaults,
            background: background,
            workspaceConnections: workspaceConnections,
            metrics: metrics,
            appReview: appReview
        )
    }
}
