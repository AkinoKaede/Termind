import Foundation
import TermindDomain

import struct TermindDomain.Host

/// Execution-only payload. Secrets are never part of the observable import preview.
nonisolated struct SSHImportBatch: Sendable {
    var hosts: [Host] = []
    var identities: [Identity] = []
    var keys: [SSHKeyRef] = []
    var knownHosts: [KnownHostEntry] = []
    var credentials: [UUID: StoredSSHKeyCredential] = [:]
}
