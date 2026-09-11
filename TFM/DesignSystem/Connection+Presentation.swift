import Foundation
import TermindDomain

extension KeyStorage {
    nonisolated var displayName: String {
        switch self {
        case .thisDevice: String(localized: "This Mac")
        case .iCloud: String(localized: "iCloud")
        case .secureEnclave: String(localized: "Secure Enclave")
        }
    }

    nonisolated var symbol: String {
        switch self {
        case .thisDevice: "lock.laptopcomputer"
        case .iCloud: "icloud.fill"
        case .secureEnclave: "checkmark.shield.fill"
        }
    }
}

extension PortForwardingRule.Kind {
    nonisolated var displayName: String {
        switch self {
        case .local: String(localized: "Local forward (-L)")
        case .remote: String(localized: "Remote forward (-R)")
        case .dynamic: String(localized: "Dynamic proxy (-D)")
        }
    }

    nonisolated var symbol: String {
        switch self {
        case .local: "arrow.right"
        case .remote: "arrow.left"
        case .dynamic: "shuffle"
        }
    }
}
