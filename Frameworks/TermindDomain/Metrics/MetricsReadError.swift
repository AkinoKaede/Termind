// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated enum MetricsReadError: LocalizedError {
    case unsupported, output
    public var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Metrics requires a Linux server with procfs.")
        case .output: String(localized: "The metrics response is incomplete or too large.")
        }
    }
}
