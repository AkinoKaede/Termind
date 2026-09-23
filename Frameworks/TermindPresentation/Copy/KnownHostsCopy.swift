import Foundation

extension TermindCopy {
    public nonisolated enum KnownHosts {
        public static var addKnownHost: LocalizedStringResource {
            "Add Known Host"
        }

        public static var deleteKnownHostConfirmation: LocalizedStringResource {
            "Delete Known Host?"
        }

        public static func deleteKnownHostsConfirmation(_ count: Int) -> LocalizedStringResource {
            "Delete \(count) Known Hosts?"
        }

        public static var editKnownHost: LocalizedStringResource {
            "Edit Known Host"
        }

        public static var hashedAddressExplanation: LocalizedStringResource {
            "The original address and port cannot be recovered from this hash."
        }

        public static var hostKey: LocalizedStringResource {
            "Host Key"
        }

        public static var importTrustedServerKeysOrAddAFingerprintManually: LocalizedStringResource {
            "Import trusted server keys or add a fingerprint manually."
        }

        public static var keyType: LocalizedStringResource {
            "Key Type"
        }

        public static var knownHostsOperationFailed: LocalizedStringResource {
            "Known Hosts Operation Failed"
        }

        public static var noKnownHosts: LocalizedStringResource {
            "No Known Hosts"
        }

        public static var deleteKnownHostWarning: LocalizedStringResource {
            "The next connection will ask you to verify the server key again."
        }

        public static var importKnownHosts: LocalizedStringResource {
            "Import Known Hosts"
        }
        public static var copyFingerprint: LocalizedStringResource {
            "Copy Fingerprint"
        }
        public static var fingerprint: LocalizedStringResource {
            "Fingerprint"
        }
    }
}
