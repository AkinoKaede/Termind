// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain
import TermindPresentation

extension KeyStorage {
    nonisolated var displayName: String {
        switch self {
        case .thisDevice: String(localized: AppStrings.Keychain.thisMac)
        case .iCloud: String(localized: AppStrings.Keychain.iCloud)
        case .secureEnclave: String(localized: AppStrings.Keychain.secureEnclave)
        case .external: String(localized: AppStrings.SecurityKey.title)
        }
    }

    nonisolated var symbol: String {
        switch self {
        case .thisDevice: "lock.laptopcomputer"
        case .iCloud: "icloud.fill"
        case .secureEnclave: "checkmark.shield.fill"
        case .external: "key.radiowaves.forward.fill"
        }
    }
}
