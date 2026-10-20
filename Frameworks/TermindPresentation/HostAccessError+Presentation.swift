// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain

// Keep localized copy in Presentation while shared policy failures retain their typed identity.
// swift-format-ignore: AvoidRetroactiveConformances
extension HostAccessError: @retroactive LocalizedError {
    /// A static reference also keeps this conformance linked in the static Presentation framework.
    public nonisolated static func presentationDescription(of error: any Error) -> String? {
        if let accessError = error as? Self { return accessError.errorDescription }
        if let wakeError = error as? WakeOnLANError { return wakeError.errorDescription }
        return error.localizedDescription
    }

    public nonisolated var errorDescription: String? {
        switch self {
        case .hostLimit: nil
        case .lockedHost: String(localized: AppStrings.Pro.upgradeToUnlockHost)
        case .verifyingEntitlement: String(localized: AppStrings.Pro.verifyingAccess)
        case .entitlementVerificationFailed: String(localized: AppStrings.Pro.accessVerificationFailed)
        }
    }
}
