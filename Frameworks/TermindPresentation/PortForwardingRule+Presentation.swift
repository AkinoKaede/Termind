import Foundation
import TermindDomain

extension PortForwardingRule {
    public nonisolated func displayName(hostName: String?) -> String {
        SavedName.resolve(label, default: defaultName(hostName: hostName ?? String(localized: "Host Unavailable")))
    }
}

extension PortForwardingRule.Kind {
    public nonisolated var shortDisplayName: String {
        switch self {
        case .local: String(localized: "Local")
        case .remote: String(localized: "Remote")
        case .dynamic: String(localized: "Dynamic")
        }
    }

    public nonisolated var displayName: String {
        switch self {
        case .local: String(localized: "Local forward (-L)")
        case .remote: String(localized: "Remote forward (-R)")
        case .dynamic: String(localized: "Dynamic proxy (-D)")
        }
    }

    public nonisolated var symbol: String {
        switch self {
        case .local: "arrow.right"
        case .remote: "arrow.left"
        case .dynamic: "shuffle"
        }
    }
}
