import Foundation
import TermindDomain

import struct TermindDomain.Host

nonisolated struct SSHAuthenticationPrompt: Identifiable, Hashable, Sendable {
    nonisolated enum Mode: Hashable, Sendable {
        case localIdentity
        case serverChallenge
    }

    let id = UUID()
    var host: Host
    var selectedIdentityID: Identity.ID? = nil
    var username: String
    var selectedKeyID: SSHKeyRef.ID?
    var failureMessage: String?
    var requiresPassphrase = false
    var mode: Mode = .localIdentity
}
