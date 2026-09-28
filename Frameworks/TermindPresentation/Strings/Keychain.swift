import Foundation

extension AppStrings {
    public nonisolated enum Keychain {
        public static var savePassphrase: LocalizedStringResource { "Save Passphrase" }
        public static var saveAndContinue: LocalizedStringResource { "Save and Continue" }

        public static var addAndConnectToAHostBeforeExportingAKeyToIt: LocalizedStringResource {
            "Add and connect to a host before exporting a key to it."
        }

        public static var algorithm: LocalizedStringResource {
            "Algorithm"
        }

        public static var certificate: LocalizedStringResource {
            "Certificate"
        }

        public static var certificateOptional: LocalizedStringResource {
            "Certificate (optional)"
        }

        public static var chooseFile: LocalizedStringResource {
            "Choose File"
        }

        public static var chooseReplacement: LocalizedStringResource {
            "Choose Replacement"
        }

        public static var cipher: LocalizedStringResource {
            "Cipher"
        }

        public static var confirmPassphrase: LocalizedStringResource {
            "Confirm Passphrase"
        }

        public static var copyPublicKey: LocalizedStringResource {
            "Copy Public Key"
        }

        public static func deleteIdentitiesConfirmation(_ count: Int) -> LocalizedStringResource {
            "Delete \(count) Identities?"
        }

        public static var deleteIdentity: LocalizedStringResource {
            "Delete Identity"
        }

        public static var deleteIdentityConfirmation: LocalizedStringResource {
            "Delete Identity?"
        }

        public static var deleteIdentityWarning: LocalizedStringResource {
            "Hosts using this identity will ask for credentials again."
        }

        public static func deleteItemsConfirmation(_ count: Int) -> LocalizedStringResource {
            "Delete \(count) Items?"
        }

        public static var deleteKey: LocalizedStringResource {
            "Delete Key"
        }

        public static var deleteKeyConfirmation: LocalizedStringResource {
            "Delete Key?"
        }

        public static var deleteKeyWarning: LocalizedStringResource {
            "Identities using this key will no longer have access to it."
        }

        public static func deleteKeysConfirmation(_ count: Int) -> LocalizedStringResource {
            "Delete \(count) Keys?"
        }

        public static var derivedFromThePrivateKey: LocalizedStringResource {
            "Derived from the private key"
        }

        public static var dragToReplace: LocalizedStringResource {
            "Drag to Replace"
        }

        public static var editIdentity: LocalizedStringResource {
            "Edit Identity"
        }

        public static var editKey: LocalizedStringResource {
            "Edit Key"
        }

        public static var ellipticCurve: LocalizedStringResource {
            "Elliptic Curve"
        }

        public static var exportToHosts: LocalizedStringResource {
            "Export to Hosts"
        }

        public static var exported: LocalizedStringResource {
            "Exported"
        }

        public static func exportedFailed(count1: Int, failures: Int) -> LocalizedStringResource {
            "\(count1) exported, \(failures) failed"
        }

        public static func exportedKeysTo1Host(_ count: Int) -> LocalizedStringResource {
            "Exported \(count) keys to 1 host"
        }

        public static func exportedKeysToHosts(count: Int, hostCount: Int) -> LocalizedStringResource {
            "Exported \(count) keys to \(hostCount) hosts"
        }

        public static var exportedTo1Host: LocalizedStringResource {
            "Exported to 1 host"
        }

        public static func exportedToHosts(_ hostCount: Int) -> LocalizedStringResource {
            "Exported to \(hostCount) hosts"
        }

        public static var generate: LocalizedStringResource {
            "Generate"
        }

        public static var generateKey: LocalizedStringResource {
            "Generate Key"
        }

        public static var iCloud: LocalizedStringResource {
            "iCloud"
        }

        public static var identities: LocalizedStringResource {
            "Identities"
        }

        public static func identityCount(_ count: Int) -> LocalizedStringResource {
            "\(count) identities"
        }

        public static var importKey: LocalizedStringResource {
            "Import Key"
        }

        public static var keyMissing: LocalizedStringResource {
            "Key missing"
        }

        public static var keySize: LocalizedStringResource {
            "Key Size"
        }

        public static var keyUnavailable: LocalizedStringResource {
            "Key Unavailable"
        }

        public static var keychainIsEmpty: LocalizedStringResource {
            "Keychain Is Empty"
        }

        public static var keychainOperationFailed: LocalizedStringResource {
            "Keychain Operation Failed"
        }

        public static var keychainUnavailable: LocalizedStringResource {
            "Keychain unavailable"
        }

        public static var keys: LocalizedStringResource {
            "Keys"
        }

        public static func keysNamed(_ count: Int) -> LocalizedStringResource {
            "\(count) keys"
        }

        public static var loadingPrivateKeyProgress: LocalizedStringResource {
            "Loading private key…"
        }

        public static var nistP256: LocalizedStringResource {
            "NIST P-256"
        }

        public static var nistP384: LocalizedStringResource {
            "NIST P-384"
        }

        public static var nistP521: LocalizedStringResource {
            "NIST P-521"
        }

        public static var noIdentities: LocalizedStringResource {
            "No Identities"
        }

        public static var noKeys: LocalizedStringResource {
            "No Keys"
        }

        public static var noSecret: LocalizedStringResource {
            "No secret"
        }

        public static var passphraseSaved: LocalizedStringResource { "Passphrase Saved" }

        public static var passphraseRequired: LocalizedStringResource {
            "Passphrase Required"
        }

        public static var passphrasesDoNotMatch: LocalizedStringResource {
            "Passphrases do not match."
        }

        public static var passwordMissing: LocalizedStringResource {
            "Password missing"
        }

        public static var passwordUnavailable: LocalizedStringResource {
            "Password unavailable"
        }

        public static var pasteAPrivateKeyOrDragOneIn: LocalizedStringResource {
            "Paste a private key, or drag one in"
        }

        public static var privateKey: LocalizedStringResource {
            "Private Key"
        }

        public static var privateKeyMissing: LocalizedStringResource {
            "Private key missing"
        }

        public static var privateKeyOrCertificate: LocalizedStringResource {
            "Private key or certificate"
        }

        public static var publicKey: LocalizedStringResource {
            "Public Key"
        }

        public static var replacePrivateKeyWarning: LocalizedStringResource {
            "Replacing this private key changes its public key. Hosts using the old key may reject the next connection."
        }

        public static var requireAuthentication: LocalizedStringResource {
            "Require Authentication"
        }

        public static var requireUserPresence: LocalizedStringResource {
            "Require User Presence"
        }

        public static var rounds: LocalizedStringResource {
            "Rounds"
        }

        public static var secureEnclave: LocalizedStringResource {
            "Secure Enclave"
        }

        public static var sshCertificate: LocalizedStringResource {
            "SSH Certificate"
        }

        public static var storeIn: LocalizedStringResource {
            "Store in"
        }

        public static var theIdentityCouldNotBeDeleted: LocalizedStringResource {
            "The identity could not be deleted."
        }

        public static var thePrivateKeyIsUnavailableOnThisMac: LocalizedStringResource {
            "The private key is unavailable on this Mac."
        }

        public static var thisDevice: LocalizedStringResource {
            "This Device"
        }

        public static var thisMac: LocalizedStringResource {
            "This Mac"
        }

        public static var unableToReadFile: LocalizedStringResource {
            "Unable to Read File"
        }

        public static var rsa2048Bits: LocalizedStringResource {
            "2048 bit"
        }

        public static var rsa3072Bits: LocalizedStringResource {
            "3072 bit"
        }

        public static var rsa4096Bits: LocalizedStringResource {
            "4096 bit"
        }

        public static var deleteItemsWarning: LocalizedStringResource {
            "Hosts and identities using these items may need to be configured again."
        }

        public static var deleteIdentitiesWarning: LocalizedStringResource {
            "Hosts using these identities will ask for credentials again."
        }

        public static var deleteKeysWarning: LocalizedStringResource {
            "Identities using these keys will no longer have access to them."
        }

        public static var emptyDescription: LocalizedStringResource {
            "Import or generate a key, then create an identity with a username. Private keys stay in the Keychain."
        }

        public static var newIdentity: LocalizedStringResource {
            "New Identity"
        }
        public static var passphrase: LocalizedStringResource {
            "Passphrase"
        }
        public static var secret: LocalizedStringResource {
            "Secret"
        }
        public static var thePrivateKeyIsUnavailableOnThisDevice: LocalizedStringResource {
            "The private key is unavailable on this device."
        }
    }
}
