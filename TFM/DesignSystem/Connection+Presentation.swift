import Foundation
import TermindDomain

extension KeyStorage {
    nonisolated var displayName: String {
        switch self {
        case .thisDevice: String(localized: "This Mac")
        case .iCloud: String(localized: "iCloud")
        case .secureEnclave: String(localized: "Secure Enclave")
        }
    }

    nonisolated var symbol: String {
        switch self {
        case .thisDevice: "lock.laptopcomputer"
        case .iCloud: "icloud.fill"
        case .secureEnclave: "checkmark.shield.fill"
        }
    }
}

extension SSHKeyAlgorithm {
    nonisolated var displayName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .ecdsa256: "ECDSA P-256"
        case .ecdsa384: "ECDSA P-384"
        case .ecdsa521: "ECDSA P-521"
        case .rsa: "RSA"
        }
    }

    nonisolated var typeName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .ecdsa256, .ecdsa384, .ecdsa521: "ECDSA"
        case .rsa: "RSA"
        }
    }
}

extension PortForwardingRule.Kind {
    nonisolated var displayName: String {
        switch self {
        case .local: String(localized: "Local forward (-L)")
        case .remote: String(localized: "Remote forward (-R)")
        case .dynamic: String(localized: "Dynamic proxy (-D)")
        }
    }

    nonisolated var symbol: String {
        switch self {
        case .local: "arrow.right"
        case .remote: "arrow.left"
        case .dynamic: "shuffle"
        }
    }
}
