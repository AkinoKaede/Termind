import Foundation

extension AppStrings {
    public nonisolated enum KeyExport {
        public static var exportAndAttach: LocalizedStringResource { "Export and Attach" }
        public static var completed: LocalizedStringResource { "Public key exported and attached." }
        public static var attachmentFailed: LocalizedStringResource {
            "Public key exported. The host could not be updated."
        }
        public static var retryAttachment: LocalizedStringResource { "Retry Attachment" }
        public static var location: LocalizedStringResource { "Location — $1" }
        public static var filename: LocalizedStringResource { "Filename — $2" }
        public static var advanced: LocalizedStringResource { "Advanced" }
        public static var script: LocalizedStringResource { "Script" }
        public static var scriptHelp: LocalizedStringResource {
            "The default script supports UNIX systems."
        }
        public static var optionalPublicKey: LocalizedStringResource {
            "Optional. If empty, the public key is derived only when exporting."
        }
        public static var passphraseHelp: LocalizedStringResource {
            "Unlock this key to derive its public key for this export."
        }
        public static var exporting: LocalizedStringResource { "Exporting public key…" }
        public static var selectHost: LocalizedStringResource { "Select Host" }
        public static var noHosts: LocalizedStringResource { "Add an SSH host before exporting a key." }
    }
}
