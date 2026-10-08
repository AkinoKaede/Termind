import Foundation
import TermindDomain

import struct TermindDomain.Host

public enum RemoteSessionAuthenticationFailure {
    case proxy(host: Host, error: any Error)
    case identity(host: Host, username: String, keyID: SSHKeyRef.ID?, saving: Bool, error: any Error)
}

extension RemoteSessionConnectionController {
    /// Callbacks are synchronous and never retained. Models own persistence policy
    /// and presentation differences; a failed save must not start another attempt.
    public func continueAuthentication(
        identityID: Identity.ID?, username: String, password: String?, passphrase: String?,
        keyID: SSHKeyRef.ID?, save: Bool, destinationID: Host.ID,
        using store: any RemoteSessionHostStore,
        stageIdentity: (Host, SSHAuthenticationSubmission) -> Void,
        saveIdentity: (Host, SSHAuthenticationSubmission, Identity?) throws -> Void,
        onFailure: (RemoteSessionAuthenticationFailure) -> Void,
        connect: () -> Void
    ) {
        guard let prompt = pendingAuthentication,
            var host = connectionHost(prompt.host.id, destinationID: destinationID, using: store)
        else { return }
        let selectedIdentity = identityID.flatMap { store.identity($0) }
        let submittedUsername = ((prompt.isProxy ? nil : selectedIdentity?.username) ?? username)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedUsername.isEmpty else { return }

        if prompt.isProxy {
            let submission = SSHProxyAuthenticationSubmission(
                username: submittedUsername, password: password, identityID: selectedIdentity?.id)
            do {
                if save {
                    host = try store.saveProxyAuthentication(
                        submission, for: host, selectedIdentity: selectedIdentity, suppliedPassword: password)
                }
                suppliedProxyAuthentications[host.id] = submission
                pendingAuthentication = nil
                journey.resume()
                connect()
            } catch {
                onFailure(.proxy(host: host, error: error))
            }
            return
        }

        if prompt.requiresPassphrase {
            do {
                suppliedAuthentications[host.id] = try store.passphraseSubmission(
                    for: prompt, existing: suppliedAuthentications[host.id], passphrase: passphrase, save: save)
                pendingAuthentication = nil
                journey.resume()
                connect()
            } catch {
                var failed = prompt
                failed.failureMessage = error.localizedDescription
                pendingAuthentication = failed
            }
            return
        }

        let submittedKeyID = selectedIdentity?.keyID ?? keyID
        var saving = false
        do {
            let submission = try store.authenticationSubmission(
                username: submittedUsername, password: password, passphrase: passphrase,
                keyID: submittedKeyID, selectedIdentity: selectedIdentity)
            suppliedAuthentications[host.id] = submission
            stageIdentity(host, submission)
            pendingAuthentication = nil
            journey.resume()
            if save {
                saving = true
                try saveIdentity(host, submission, selectedIdentity)
            }
        } catch {
            onFailure(
                .identity(
                    host: host, username: submittedUsername, keyID: submittedKeyID,
                    saving: saving, error: error))
            return
        }
        connect()
    }
}
