import Foundation

/// A host key Termind has accepted, i.e. one line of `known_hosts`.
///
/// This is the only security-relevant record that is safe — and worth — syncing:
/// a fingerprint pinned on one machine should be pinned on all of them, so a
/// swapped key is caught the first time any device sees it rather than the third.
/// Nothing secret lives here; a public key fingerprint is public by construction.
public nonisolated struct KnownHostEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var hostname: String
    public var port: Int = 22
    public var algorithm: SSHKeyAlgorithm = .ed25519
    public var fingerprint: String = ""
    public var addedAt: Date = Date(timeIntervalSince1970: 0)
    /// True once the key the server presented stopped matching the pinned one.
    /// Kept as data rather than a transient alert so the warning survives the
    /// dialog the user dismissed at 3am.
    public var isMismatched: Bool = false

    public var identity: SSHHostKeyIdentity {
        SSHHostKeyIdentity(algorithm: algorithm, fingerprint: fingerprint)
    }
    public init(
        id: UUID = UUID(), hostname: String, port: Int = 22, algorithm: SSHKeyAlgorithm = .ed25519,
        fingerprint: String = "", addedAt: Date = Date(timeIntervalSince1970: 0), isMismatched: Bool = false
    ) {
        self.id = id
        self.hostname = hostname
        self.port = port
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.addedAt = addedAt
        self.isMismatched = isMismatched
    }

}

nonisolated extension KnownHostEntry {
    public var isHashed: Bool { hostname.hasPrefix("|") }

    public var displayAddress: String {
        isHashed ? hostname : Host(name: "", host: hostname, port: port).displayAddress
    }

    public func matches(hostname candidate: String, port candidatePort: Int) -> Bool {
        if isHashed {
            return SSHKnownHostMatcher.matches(hash: hostname, hostname: candidate, port: candidatePort)
        }
        return hostname.caseInsensitiveCompare(candidate) == .orderedSame && port == candidatePort
    }

    public var isValid: Bool {
        let addressValid =
            isHashed
            ? SSHKnownHostMatcher.isValidHash(hostname)
            : !hostname.isEmpty && !hostname.contains(where: { $0.isWhitespace || "*,!?|[]".contains($0) })
                && (1...65_535).contains(port)
        return addressValid && !fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
