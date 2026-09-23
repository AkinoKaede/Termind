import Foundation
import TermindDomain
import TermindPresentation

extension KeyStorage {
    nonisolated var displayName: String {
        switch self {
        case .thisDevice: String(localized: TermindCopy.Keychain.thisMac)
        case .iCloud: String(localized: TermindCopy.Keychain.iCloud)
        case .secureEnclave: String(localized: TermindCopy.Keychain.secureEnclave)
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
