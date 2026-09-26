import Foundation
import SwiftData
import TermindApplication
import TermindInfrastructure
import TermindRemoteInfrastructure

@MainActor
struct MobileAppDependencies {
    var hosts: (any HostRepository)?
    var inMemory: Bool
    var defaults: UserDefaults?
    var background: any MobileBackgroundTaskManaging
    var workspaceConnections: MobileWorkspaceConnectionServices
    var metrics: MobileMetricsServices
    var appReview: AppReviewController
    var logging: any ApplicationLogManaging = DisabledApplicationLogManager.shared
    var connectionCoordinator: RemoteConnectionCoordinator = RemoteConnectionCoordinator()
    var container: ModelContainer? = nil
    var workspaceStore: MobileWorkspaceStore? = nil
    var liveActivities: MobileLiveActivityController? = nil
    var activateWorkspaceSession: @MainActor (String, UUID, @escaping @MainActor () -> Void) -> Void =
        MobileWorkspaceSceneRouting.activate
    var makeForwardings: (HostLibraryModel) -> PortForwardingController = { PortForwardingController(hosts: $0) }

    static func live() -> MobileAppDependencies {
        let logging = LaunchFileLogService()
        let coordinator = RemoteConnectionCoordinator(
            logger: logging.makeLogger(label: "termind.remote-connection"))
        return MobileAppDependencies(
            hosts: nil,
            inMemory: false,
            defaults: .standard,
            background: MobileBackgroundController(),
            workspaceConnections: .live(coordinator: coordinator),
            metrics: .live(coordinator: coordinator),
            appReview: .live(),
            logging: logging,
            connectionCoordinator: coordinator,
            makeForwardings: {
                PortForwardingController(
                    hosts: $0, logger: logging.makeLogger(label: "termind.port-forwarding"))
            }
        )
    }

    static func testing(
        hosts: (any HostRepository)? = nil,
        defaults: UserDefaults? = nil,
        background: any MobileBackgroundTaskManaging = MobileBackgroundController(),
        workspaceConnections: MobileWorkspaceConnectionServices = .live,
        metrics: MobileMetricsServices = .testing,
        appReview: AppReviewController = AppReviewController()
    ) -> MobileAppDependencies {
        MobileAppDependencies(
            hosts: hosts,
            inMemory: true,
            defaults: defaults,
            background: background,
            workspaceConnections: workspaceConnections,
            metrics: metrics,
            appReview: appReview
        )
    }
}
