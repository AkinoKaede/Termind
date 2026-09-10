import Foundation

/// A host key Termind has accepted, i.e. one line of `known_hosts`.
///
/// This is the only security-relevant record that is safe — and worth — syncing:
/// a fingerprint pinned on one machine should be pinned on all of them, so a
/// swapped key is caught the first time any device sees it rather than the third.
/// Nothing secret lives here; a public key fingerprint is public by construction.
nonisolated struct KnownHostEntry: Identifiable, Codable, Hashable, Sendable {
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

}

nonisolated extension KnownHostEntry {
    var isHashed: Bool { hostname.hasPrefix("|") }

    var displayAddress: String {
        isHashed ? hostname : Host(name: "", host: hostname, port: port).displayAddress
    }

    func matches(hostname candidate: String, port candidatePort: Int) -> Bool {
        if isHashed {
            return SSHKnownHostMatcher.matches(hash: hostname, hostname: candidate, port: candidatePort)
        }
        return hostname.caseInsensitiveCompare(candidate) == .orderedSame && port == candidatePort
    }

    var isValid: Bool {
        let addressValid =
            isHashed
            ? SSHKnownHostMatcher.isValidHash(hostname)
            : !hostname.isEmpty && !hostname.contains(where: { $0.isWhitespace || "*,!?|[]".contains($0) })
                && (1...65_535).contains(port)
        return addressValid && !fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
