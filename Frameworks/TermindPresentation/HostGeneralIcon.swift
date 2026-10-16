import Foundation

public nonisolated enum HostGeneralIcon: String, CaseIterable, Identifiable, Sendable {
    case server
    case cloud
    case terminal
    case code
    case database
    case storage
    case container
    case network
    case shield
    case homeLab = "home_lab"
    case web
    case api
    case compute
    case cluster
    case router
    case automation
    case monitoring
    case backup
    case media
    case git
    case artificialIntelligence = "ai"
    case virtualMachine = "virtual_machine"

    public var id: String { rawValue }

    public var title: LocalizedStringResource {
        switch self {
        case .server: AppStrings.HostIcons.server
        case .cloud: AppStrings.HostIcons.cloud
        case .terminal: AppStrings.Settings.terminal
        case .code: AppStrings.HostIcons.code
        case .database: AppStrings.HostIcons.database
        case .storage: AppStrings.HostIcons.storage
        case .container: AppStrings.HostIcons.container
        case .network: AppStrings.HostIcons.network
        case .shield: AppStrings.HostIcons.shield
        case .homeLab: AppStrings.HostIcons.homeLab
        case .web: AppStrings.HostIcons.web
        case .api: AppStrings.HostIcons.api
        case .compute: AppStrings.HostIcons.compute
        case .cluster: AppStrings.HostIcons.cluster
        case .router: AppStrings.HostIcons.router
        case .automation: AppStrings.HostIcons.automation
        case .monitoring: AppStrings.HostIcons.monitoring
        case .backup: AppStrings.HostIcons.backup
        case .media: AppStrings.HostIcons.media
        case .git: AppStrings.HostIcons.git
        case .artificialIntelligence: AppStrings.Settings.ai
        case .virtualMachine: AppStrings.HostIcons.virtualMachine
        }
    }

    public var systemImageName: String {
        switch self {
        case .server: "server.rack"
        case .cloud: "cloud"
        case .terminal: "terminal"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .database: "cylinder"
        case .storage: "internaldrive"
        case .container: "shippingbox"
        case .network: "network"
        case .shield: "shield"
        case .homeLab: "house"
        case .web: "globe"
        case .api: "curlybraces"
        case .compute: "cpu"
        case .cluster: "circle.grid.3x3"
        case .router: "wifi.router"
        case .automation: "gearshape.2"
        case .monitoring: "chart.xyaxis.line"
        case .backup: "externaldrive.badge.timemachine"
        case .media: "play.rectangle"
        case .git: "arrow.triangle.branch"
        case .artificialIntelligence: "brain"
        case .virtualMachine: "square.stack.3d.up"
        }
    }
}
