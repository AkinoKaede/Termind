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
