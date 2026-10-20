// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing
import UIKit

@testable import TermindIOS

@Suite @MainActor
struct MobileCompactCardTests {
    @Test func missingCredentialsRemainVisibleAsCompactWarnings() throws {
        let app = try MobileAppModel(inMemory: true)
        let missingKey = SSHKeyRef(
            label: "Unavailable key", algorithm: .ed25519, credentialRef: "missing.\(UUID())")
        try app.credentials.upsert(missingKey)
        let keyCard = MobileKeyCredentialCard(key: missingKey, credentials: app.credentials, compact: true)
        #expect(keyCard.compactWarnings.contains(AppStrings.Keychain.privateKeyMissing))

        let identity = Identity(name: "", username: "deploy", keyID: UUID())
        let identityCard = MobileIdentityCredentialCard(
            identity: identity, credentials: app.credentials, compact: true)
        #expect(identityCard.compactWarnings.contains(AppStrings.Keychain.keyMissing))
        let empty = MobileIdentityCredentialCard(
            identity: Identity(name: "Draft", username: "deploy"), credentials: app.credentials, compact: true)
        #expect(empty.compactWarnings == [AppStrings.Keychain.noSecret])
    }

    @Test func forwardingBadgesDistinguishIdleProgressSuccessAndFailure() {
        let rule = PortForwardingRule(hostID: UUID())
        func badge(_ runtime: PortForwardingRuntimeState) -> MobileCompactCardBadge? {
            MobileForwardingCardContent(rule: rule, hostName: "Gateway", runtime: runtime, compact: true).compactBadge
        }
        #expect(badge(.stopped) == nil)
        #expect(badge(.connecting)?.symbol == "clock.fill")
        #expect(badge(.awaitingAuthentication)?.symbol == "clock.fill")
        #expect(badge(.running(activeConnections: 1))?.symbol == "checkmark.circle.fill")
        #expect(badge(.failed("Unavailable"))?.symbol == "exclamationmark.triangle.fill")
    }

    @Test func compactSnippetsRetainTheExistingRiskClassification() {
        let safe = MobileCompactSnippetCardContent(snippet: Snippet(title: "Inspect", body: "pwd"))
        let destructive = MobileCompactSnippetCardContent(snippet: Snippet(title: "Delete", body: "rm -rf /"))
        #expect(safe.riskTitle == AppStrings.Snippets.readOnlyRisk)
        #expect(destructive.riskTitle == AppStrings.Snippets.destructiveRisk)
    }

    @Test(arguments: [
        ("en", "Compact"), ("zh-Hans", "紧凑"), ("zh-Hant", "緊湊"),
        ("ja", "コンパクト"), ("ko", "컴팩트"), ("de", "Kompakt"), ("fr", "Compact"),
    ])
    func appearanceSwitchDoesNotUseTheContextCompressionTranslation(language: String, expected: String) {
        #expect(
            AppLocalization.resolve(AppStrings.Settings.compactCards, locale: Locale(identifier: language)) == expected)
    }

}
