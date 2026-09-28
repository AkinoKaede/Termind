extension SSHKeyAlgorithm {
    public nonisolated var displayName: String {
        switch self {
        case .securityKey: "ECDSA-SK P-256"
        case .ed25519: "Ed25519"
        case .ecdsa256: "ECDSA P-256"
        case .ecdsa384: "ECDSA P-384"
        case .ecdsa521: "ECDSA P-521"
        case .rsa: "RSA"
        }
    }

    public nonisolated var typeName: String {
        switch self {
        case .securityKey: "Security Key"
        case .ed25519: "Ed25519"
        case .ecdsa256, .ecdsa384, .ecdsa521: "ECDSA"
        case .rsa: "RSA"
        }
    }
}
