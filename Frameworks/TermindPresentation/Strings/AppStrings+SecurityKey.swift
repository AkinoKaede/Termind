import Foundation

extension AppStrings {
    public nonisolated enum SecurityKey {
        public static var continueAction: LocalizedStringResource { "Continue" }
        public static var required: LocalizedStringResource { "Required" }
        public static var preferred: LocalizedStringResource { "Preferred" }
        public static var discouraged: LocalizedStringResource { "Discouraged" }
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
