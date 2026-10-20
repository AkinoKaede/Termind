// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

nonisolated enum ApplicationIdentity {
    /// What the app calls itself on screen — the Welcome page's heading and,
    /// through `VaultWindowTitleProvider`, the window title while it is showing.
    /// Read from the bundle so a rename lands in one place.
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Termind"
    }

    static var teamIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "TermindTeamIdentifier") as? String
            ?? "F6SUNDBBN9"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.akinokaede.termind"
    }

    static var keychainAccessGroup: String {
        "\(teamIdentifier).\(bundleIdentifier)"
    }
}
