import Foundation

nonisolated enum PasswordStorage: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case thisDevice
    case iCloudKeychain

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thisDevice: String(localized: "This Mac")
        case .iCloudKeychain: String(localized: "iCloud")
        }
    }

    var symbol: String {
        switch self {
        case .thisDevice: "lock.laptopcomputer"
        case .iCloudKeychain: "icloud.fill"
        }
    }
}

/// How an Identity edit changes the password stored behind `credentialRef`.
///
/// `nil` could only mean one of "keep" and "remove", which made it impossible
/// for the editor to offer both operations without guessing. Keeping the three
/// intents explicit also lets `HostLibraryModel` update the model and Keychain as one
/// operation.
nonisolated enum IdentityPasswordUpdate: Hashable, Sendable {
    case keep
    case replace(String)
    case remove
}

nonisolated enum SecretAvailability: Equatable, Sendable {
    case notConfigured
    case available
    case missing
    case failed(String)
}

/// A named way of logging in: a username plus a *reference* to the secret.
///
/// Split out from `Host` because the same login is usually reused across a whole
/// fleet — twelve boxes, one `deploy` account, one key. Editing the key in one
/// place then fixes twelve hosts, and the Keychain holds one item instead of
/// twelve copies of the same one.
///
/// The two secrets are independent, and a login may well have both: a key for
/// day-to-day use and a password for the same account at the console, or a key
/// that gets you in and a password `sudo` then asks for. Modelling them as a
/// choice forced a lie in one direction or the other, so each is its own
/// optional and either, both, or neither may be set.
///
/// Nothing secret is stored here regardless. `credentialRef` is a lookup string —
/// "the password is filed under this name" — and `keyID` points at an `SSHKeyRef`,
/// which is itself only a reference. Neither the key nor the password has a path
/// into this struct, so neither has a path into SwiftData or CloudKit.
nonisolated struct Identity: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var username: String
    /// Where to look the password up. Empty means this identity has no password.
    var credentialRef: String = ""
    /// The secret itself never enters SwiftData. This value only selects the
    /// Data Protection Keychain class used to resolve `credentialRef`.
    var passwordStorage: PasswordStorage = .iCloudKeychain
    /// One of the entries on the Keys list. Storing the id rather than the key
    /// means renaming or rotating a key never touches the identities that use
    /// it. `nil` means this identity has no key.
    var keyID: SSHKeyRef.ID?
    var notes: String = ""
    var lastUsedAt: Date?
    /// User-defined position on the Keychain page. It is independent from the
    /// display name so renaming an identity never silently moves its card.
    var sortIndex: Double = 0

    var usesPassword: Bool { !credentialRef.isEmpty }

    var usesKey: Bool { keyID != nil }

    /// Proxy authentication can only consume a username and a saved password;
    /// SSH keys on the same Identity are deliberately irrelevant here.
    var isProxyEligible: Bool {
        usesPassword
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// An identity with neither is legal — it is a login name waiting for its
    /// secret — and the Keychain page says so on the card rather than hiding it.
    var hasSecret: Bool { usesPassword || usesKey }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return name.lowercased().contains(q)
            || username.lowercased().contains(q)
            || notes.lowercased().contains(q)
    }
}
