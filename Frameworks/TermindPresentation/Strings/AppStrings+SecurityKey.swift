import Foundation

extension AppStrings {
    public nonisolated enum SecurityKey {
        public static var continueAction: LocalizedStringResource { "Continue" }
        public static var required: LocalizedStringResource { "Required" }
        public static var preferred: LocalizedStringResource { "Preferred" }
        public static var discouraged: LocalizedStringResource { "Discouraged" }
        public static var invalidCredential: LocalizedStringResource { "The WebAuthn credential reference is invalid." }
        public static var invalidResponse: LocalizedStringResource {
            "The WebAuthn response could not be verified."
        }
        public static var unsupportedResponse: LocalizedStringResource {
            "The WebAuthn response is not compatible with SSH."
        }
        public static var publicKeyRejected: LocalizedStringResource {
            "The server rejected the username or public key. Check the login user and the key in authorized_keys."
        }
        public static var title: LocalizedStringResource { "Security Key" }
        public static var touchPrompt: LocalizedStringResource {
            "Follow the system prompt to complete security key authentication."
        }
        public static var verification: LocalizedStringResource { "User Verification" }
        public static var reference: LocalizedStringResource { "Reference" }
        public static var importHelp: LocalizedStringResource {
            "Paste a WebAuthn credential reference."
        }
    }
}
