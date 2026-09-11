import Foundation

nonisolated enum MobileDestination: String, CaseIterable, Identifiable {
    case vault, metrics, workspaces, assistant, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .vault: String(localized: "Vault")
        case .assistant: String(localized: "Assistant")
        case .workspaces: String(localized: "Workspaces")
        case .metrics: String(localized: "Metrics")
        case .settings: String(localized: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .vault: "server.rack"
        case .assistant: "sparkles"
        case .workspaces: "terminal"
        case .metrics: "gauge.with.dots.needle.33percent"
        case .settings: "gearshape"
        }
    }
}

nonisolated enum MobileTab: String, CaseIterable {
    case vault, workspaces, assistant, settings
}
