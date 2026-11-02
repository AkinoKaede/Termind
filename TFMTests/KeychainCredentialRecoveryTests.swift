// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Security
import TermindApplication
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct KeychainCredentialRecoveryTests {
    @Test func interactionNotAllowedIsARecoverableReadFailure() {
        #expect(KeychainSecretStore.readFailure(for: errSecInteractionNotAllowed) is SSHCredentialAccessUnavailable)
    }

    @Test(arguments: [errSecAuthFailed, errSecMissingEntitlement, errSecNotAvailable, errSecDecode])
    func otherKeychainFailuresPreserveTheirStatus(_ status: OSStatus) {
        let failure = KeychainSecretStore.readFailure(for: status)
        guard case .status(let original) = failure as? KeychainSecretError else {
            Issue.record("Unrelated Keychain errors must not enter an indefinite credential retry")
            return
        }
        #expect(original == status)
    }
}
