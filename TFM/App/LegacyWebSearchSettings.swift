// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Removes search configuration that became both unused and unreachable when
/// ScrubberKit replaced the selectable Web Search backends.
@MainActor
enum LegacyWebSearchSettings {
    static let backendKey = "search.backend"
    static let baseURLKey = "search.baseURL"
    static let credentialReferenceKey = "search.credentialRef"

    static func remove(
        defaults: UserDefaults = .standard,
        deleteSecret: (String) throws -> Void
    ) {
        defaults.removeObject(forKey: backendKey)
        defaults.removeObject(forKey: baseURLKey)

        guard let reference = defaults.string(forKey: credentialReferenceKey),
            !reference.isEmpty
        else {
            defaults.removeObject(forKey: credentialReferenceKey)
            return
        }

        do {
            try deleteSecret(reference)
            defaults.removeObject(forKey: credentialReferenceKey)
        } catch {
            // Keep the reference so the next launch can retry. Removing it on
            // failure would strand an unreachable Keychain item permanently.
        }
    }
}
