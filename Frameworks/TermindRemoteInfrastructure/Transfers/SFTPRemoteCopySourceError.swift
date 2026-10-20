// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

nonisolated struct SFTPRemoteCopySourceError: LocalizedError {
    var path: String
    var errorDescription: String? {
        String(localized: "Unsupported or invalid SFTP copy source: \(path)")
    }
}
