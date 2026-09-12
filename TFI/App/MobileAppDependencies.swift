import Foundation
import TermindApplication

@MainActor
struct MobileAppDependencies {
    var hosts: (any HostRepository)?
    var inMemory: Bool
    var defaults: UserDefaults?
    var forwardingDefaults: UserDefaults?
    var background: any MobileBackgroundTaskManaging
    var workspaceConnections: MobileWorkspaceConnectionServices

    static func live() -> MobileAppDependencies {
        MobileAppDependencies(
            hosts: nil,
            inMemory: false,
            defaults: .standard,
            forwardingDefaults: .standard,
            background: MobileBackgroundController(),
            workspaceConnections: .live
        )
    }

    static func testing(
        hosts: (any HostRepository)? = nil,
        defaults: UserDefaults? = nil,
        forwardingDefaults: UserDefaults? = nil,
        background: any MobileBackgroundTaskManaging = MobileBackgroundController(),
        workspaceConnections: MobileWorkspaceConnectionServices = .live
    ) -> MobileAppDependencies {
        MobileAppDependencies(
            hosts: hosts,
            inMemory: true,
            defaults: defaults,
            forwardingDefaults: forwardingDefaults,
            background: background,
            workspaceConnections: workspaceConnections
        )
    }
}
