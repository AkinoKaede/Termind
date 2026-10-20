// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindApplication
import Testing

@Suite @MainActor
struct SSHKeyReplacementDraftTests {
    @Test func restoringOriginalPrivateKeyRestoresOnlyAutomaticallyClearedFields() {
        var draft = SSHKeyReplacementDraft()
        var publicKey = "original-public"
        var passphrase = "original-passphrase"
        for _ in 0..<2 {
            draft.privateKeyChanged(
                from: "original", to: "replacement", originalPrivateKey: "original",
                originalPublicKey: "original-public", originalPassphrase: "original-passphrase",
                publicKey: &publicKey, passphrase: &passphrase)
            #expect(publicKey.isEmpty && passphrase.isEmpty)
            draft.privateKeyChanged(
                from: "replacement", to: "another-replacement", originalPrivateKey: "original",
                originalPublicKey: "original-public", originalPassphrase: "original-passphrase",
                publicKey: &publicKey, passphrase: &passphrase)
            #expect(publicKey.isEmpty && passphrase.isEmpty)
            draft.privateKeyChanged(
                from: "another-replacement", to: "original", originalPrivateKey: "original",
                originalPublicKey: "original-public", originalPassphrase: "original-passphrase",
                publicKey: &publicKey, passphrase: &passphrase)
            #expect(publicKey == "original-public" && passphrase == "original-passphrase")
        }
    }

    @Test func revertingPrivateKeyPreservesPreviouslyRemovedFields() {
        var draft = SSHKeyReplacementDraft()
        var publicKey = ""
        var passphrase = ""
        draft.privateKeyChanged(
            from: "original", to: "replacement", originalPrivateKey: "original",
            originalPublicKey: "original-public", originalPassphrase: "original-passphrase",
            publicKey: &publicKey, passphrase: &passphrase)
        draft.privateKeyChanged(
            from: "replacement", to: "original", originalPrivateKey: "original",
            originalPublicKey: "original-public", originalPassphrase: "original-passphrase",
            publicKey: &publicKey, passphrase: &passphrase)
        #expect(publicKey.isEmpty && passphrase.isEmpty)
    }

    @Test func revertingPrivateKeyDoesNotOverwriteNewlyEnteredFields() {
        var draft = SSHKeyReplacementDraft()
        var publicKey = "original-public"
        var passphrase = "original-passphrase"
        draft.privateKeyChanged(
            from: "original", to: "replacement", originalPrivateKey: "original",
            originalPublicKey: "original-public", originalPassphrase: "original-passphrase",
            publicKey: &publicKey, passphrase: &passphrase)
        publicKey = "edited-public"
        passphrase = "edited-passphrase"
        draft.privateKeyChanged(
            from: "replacement", to: "original", originalPrivateKey: "original",
            originalPublicKey: "original-public", originalPassphrase: "original-passphrase",
            publicKey: &publicKey, passphrase: &passphrase)
        #expect(publicKey == "edited-public" && passphrase == "edited-passphrase")
    }
}
