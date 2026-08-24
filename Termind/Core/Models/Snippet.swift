import Foundation

#if canImport(UIKit)
    import UIKit
#endif

nonisolated enum KeyStorage: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case localKeychain
    case iCloudKeychain
    case secureEnclave

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localKeychain:
            #if os(macOS)
                String(localized: "This Mac")
            #elseif os(iOS)
                UIDevice.current.userInterfaceIdiom == .pad
                    ? String(localized: "This iPad")
                    : String(localized: "This iPhone")
            #else
                String(localized: "This Device")
            #endif
        case .iCloudKeychain: String(localized: "iCloud")
        case .secureEnclave: String(localized: "Secure Enclave")
        }
    }

    var symbol: String {
        switch self {
        case .localKeychain: "lock.laptopcomputer"
        case .iCloudKeychain: "icloud.fill"
        case .secureEnclave: "checkmark.shield.fill"
        }
    }
}

/// A folder used only to organise snippets. Execution settings deliberately
/// stay on the snippet, so moving a card never changes where it runs.
nonisolated struct SnippetPackage: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var parentID: SnippetPackage.ID?
    var sortIndex: Double = 0
    var isExpanded: Bool = true
}

/// A reusable multi-line script with the hosts it normally opens and runs on.
nonisolated struct Snippet: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var body: String
    var packageID: SnippetPackage.ID?
    var targetHostIDs: [Host.ID] = []
    var sortIndex: Double = 0

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return title.lowercased().contains(q)
            || body.lowercased().contains(q)
    }
}

/// The SSH public-key algorithms Termind can generate or verify.
///
/// One shared type keeps identity keys and pinned host keys from drifting into
/// separate stringly-typed lists of the same protocol values.
nonisolated enum SSHKeyAlgorithm: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case ed25519 = "ssh-ed25519"
    case ecdsa256 = "ecdsa-sha2-nistp256"
    case ecdsa384 = "ecdsa-sha2-nistp384"
    case ecdsa521 = "ecdsa-sha2-nistp521"
    case rsa = "ssh-rsa"

    nonisolated var id: Self { self }

    var displayName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .ecdsa256: "ECDSA P-256"
        case .ecdsa384: "ECDSA P-384"
        case .ecdsa521: "ECDSA P-521"
        case .rsa: "RSA"
        }
    }

    var typeName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .ecdsa256, .ecdsa384, .ecdsa521: "ECDSA"
        case .rsa: "RSA"
        }
    }
}

/// Metadata about a key pair. The private key stays in the Keychain; only the
/// public half and a lookup reference are safe to sync.
nonisolated struct SSHKeyRef: Identifiable, Hashable, Sendable {

    var id: UUID = UUID()
    var label: String
    var algorithm: SSHKeyAlgorithm = .ed25519
    var publicKey: String = ""
    var fingerprint: String = ""
    var credentialRef: String = ""
    var storage: KeyStorage = .localKeychain
    var keySize: Int?
    var hasPassphrase = false
    /// Saving a passphrase is always explicit; new keys default to asking when used.
    var storesPassphrase = false
    var requiresUserPresence = false
    var createdAt: Date = Date(timeIntervalSince1970: 0)
    /// User-defined position in the Keys section of the Keychain page.
    var sortIndex: Double = 0

    var requiresPassphraseEntry: Bool { hasPassphrase && !storesPassphrase }
}

nonisolated struct PortForwardingRule: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case local, remote, dynamic

        nonisolated var id: String { rawValue }

        /// `String(localized:)` rather than a bare literal so the String Catalog
        /// picks these up even though they sit outside a `View`.
        var displayName: String {
            switch self {
            case .local: String(localized: "Local forward (-L)")
            case .remote: String(localized: "Remote forward (-R)")
            case .dynamic: String(localized: "Dynamic proxy (-D)")
            }
        }

        var symbol: String {
            switch self {
            case .local: "arrow.right"
            case .remote: "arrow.left"
            case .dynamic: "shuffle"
            }
        }
    }

    var id: UUID = UUID()
    var hostID: Host.ID
    var kind: Kind = .local
    var bindHost: String = "127.0.0.1"
    var bindPort: Int = 8080
    var targetHost: String? = "localhost"
    var targetPort: Int? = 80
    var label: String = ""

    init(
        id: UUID = UUID(), hostID: Host.ID, kind: Kind = .local,
        bindHost: String = "127.0.0.1", bindPort: Int = 8080,
        targetHost: String? = "localhost", targetPort: Int? = 80,
        label: String = ""
    ) {
        self.id = id
        self.hostID = hostID
        self.kind = kind
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.targetHost = kind == .dynamic ? nil : targetHost
        self.targetPort = kind == .dynamic ? nil : targetPort
        self.label = label
    }

    var isValid: Bool {
        guard !bindHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (1...65_535).contains(bindPort)
        else { return false }
        if kind == .dynamic { return true }
        return targetHost?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && targetPort.map { (1...65_535).contains($0) } == true
    }

    var bindAddress: String { Self.address(bindHost, port: bindPort) }

    var summary: String {
        switch kind {
        case .local:
            "\(bindAddress) → \(Self.address(targetHost ?? "", port: targetPort ?? 0))"
        case .remote:
            "SSH \(bindAddress) → This Mac \(Self.address(targetHost ?? "", port: targetPort ?? 0))"
        case .dynamic: "SOCKS5 \(bindAddress)"
        }
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return label.lowercased().contains(q)
            || summary.lowercased().contains(q)
            || kind.displayName.lowercased().contains(q)
    }

    private static func address(_ host: String, port: Int) -> String {
        "\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }
}

typealias PortForwardingKind = PortForwardingRule.Kind
