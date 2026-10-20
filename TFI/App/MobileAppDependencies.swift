// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import SwiftData
import TermindApplication
import TermindInfrastructure
import TermindPresentation
import TermindRemoteInfrastructure

@MainActor
struct MobileAppDependencies {
    private nonisolated static let toolPresenters = SSHExecToolPresentation.registering(
        in: TermindAgentTools.presenterRegistry)

    nonisolated static func toolPresenter(for descriptor: AgentToolDescriptor) -> AgentToolDetailPresenter? {
        guard let registered = TermindAgentTools.presenter(for: descriptor) else { return nil }
        return toolPresenters.presenter(id: registered.id)
    }

    var hosts: (any HostRepository)?
    var inMemory: Bool
    var defaults: UserDefaults?
    var background: any MobileBackgroundTaskManaging
    var workspaceConnections: MobileWorkspaceConnectionServices
    var metrics: MobileMetricsServices
    var appReview: AppReviewController
    var proAccess: ProAccessController?
    var diagnosis = DiagnosisController()
    var logging: any ApplicationLogManaging = DisabledApplicationLogManager.shared
    var connectionCoordinator: RemoteConnectionCoordinator = RemoteConnectionCoordinator()
    var persistentSessionTerminator = RemoteSessionTerminator.live(coordinator: RemoteConnectionCoordinator())
    var container: ModelContainer? = nil
    var liveActivities: MobileLiveActivityController? = nil
    var terminalRecoveryStore: TerminalRecoveryStore = .shared
    var terminalEffects = MobileTerminalEffects()
    var createWorkspaceWindow: @MainActor (UUID, @escaping @MainActor () -> Void) -> Void =
        MobileWorkspaceSceneRouting.createWindow
    var activateWorkspaceSession: @MainActor (String, UUID, @escaping @MainActor () -> Void) -> Void =
        MobileWorkspaceSceneRouting.activate
    var closeWorkspaceSession: @MainActor (String, @escaping @MainActor (any Error) -> Void) -> Void =
        MobileWorkspaceSceneRouting.close
    var openWorkspaceSessionIDs: @MainActor () -> Set<String> = MobileWorkspaceSceneRouting.openSessionIDs
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
            diagnosis: DiagnosisController(defaults: .standard, reporter: FirebaseDiagnosticDataReporter.live()),
            logging: logging,
            connectionCoordinator: coordinator,
            persistentSessionTerminator: .live(coordinator: coordinator),
            terminalEffects: .live,
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
