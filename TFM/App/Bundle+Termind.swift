// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

extension Bundle {
    /// User-facing release version, also sent to MCP servers as client info.
    nonisolated static var termindVersion: String {
        main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Internal build number incremented independently of the release version.
    nonisolated static var termindBuildVersion: String {
        main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Standard macOS presentation: marketing version followed by build number.
    nonisolated static var termindDisplayVersion: String {
        "\(termindVersion) (\(termindBuildVersion))"
    }
}
