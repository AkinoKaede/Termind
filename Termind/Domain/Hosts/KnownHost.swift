import Foundation

/// A host key Termind has accepted, i.e. one line of `known_hosts`.
///
/// This is the only security-relevant record that is safe — and worth — syncing:
/// a fingerprint pinned on one machine should be pinned on all of them, so a
/// swapped key is caught the first time any device sees it rather than the third.
/// Nothing secret lives here; a public key fingerprint is public by construction.
nonisolated struct KnownHostEntry: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var hostname: String
    var port: Int = 22
    var algorithm: SSHKeyAlgorithm = .ed25519
    var fingerprint: String = ""
    var addedAt: Date = Date(timeIntervalSince1970: 0)
    /// True once the key the server presented stopped matching the pinned one.
    /// Kept as data rather than a transient alert so the warning survives the
    /// dialog the user dismissed at 3am.
    var isMismatched: Bool = false

    var identity: SSHHostKeyIdentity {
        SSHHostKeyIdentity(algorithm: algorithm, fingerprint: fingerprint)
    }

    /// OpenSSH spells a non-default port `[host]:port`, and matching that is one
    /// less thing to explain to someone importing their own `known_hosts`.
    var displayAddress: String {
        port == 22 ? hostname : "[\(hostname)]:\(port)"
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return hostname.lowercased().contains(q)
            || fingerprint.lowercased().contains(q)
            || algorithm.rawValue.lowercased().contains(q)
    }
}
