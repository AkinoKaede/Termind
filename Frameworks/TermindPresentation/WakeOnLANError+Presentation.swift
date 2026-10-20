// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication

// swift-format-ignore: AvoidRetroactiveConformances
extension WakeOnLANError: @retroactive LocalizedError {
    public nonisolated var errorDescription: String? {
        switch self {
        case .invalidAddress: String(localized: AppStrings.LocalNetwork.invalidMACAddress)
        case .noLocalNetwork, .sendFailed: String(localized: AppStrings.LocalNetwork.wakeFailed)
        }
    }
}
