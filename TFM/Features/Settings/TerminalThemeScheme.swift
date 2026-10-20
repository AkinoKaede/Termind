// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

nonisolated enum TerminalCustomConfigurationScheme: String, Identifiable, Hashable, Sendable {
    case light
    case dark

    var id: String { rawValue }
}
