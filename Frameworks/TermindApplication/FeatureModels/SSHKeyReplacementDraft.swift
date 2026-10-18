import Foundation

/// Retains only fields cleared automatically while replacing an existing private key.
/// This editor-local state must be cleared with the rest of the sensitive draft.
public struct SSHKeyReplacementDraft {
    private var clearedPublicKey: String?
    private var clearedPassphrase: String?

    public init() {}

    public mutating func privateKeyChanged(
        from oldValue: String, to value: String, originalPrivateKey: String,
        originalPublicKey: String, originalPassphrase: String,
        publicKey: inout String, passphrase: inout String
    ) {
        guard !originalPrivateKey.isEmpty, oldValue != value else { return }
        if value == originalPrivateKey {
            if let clearedPublicKey, publicKey.isEmpty { publicKey = clearedPublicKey }
            if let clearedPassphrase, passphrase.isEmpty { passphrase = clearedPassphrase }
            clearedPublicKey = nil
            clearedPassphrase = nil
        } else {
            if publicKey == originalPublicKey, !publicKey.isEmpty {
                clearedPublicKey = publicKey
                publicKey = ""
            }
            if oldValue == originalPrivateKey, !originalPassphrase.isEmpty {
                clearedPassphrase = passphrase
                passphrase = ""
            }
        }
    }
}
