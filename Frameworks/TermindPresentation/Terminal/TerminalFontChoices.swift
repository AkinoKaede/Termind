// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Only enumerated, usable families may appear in either section.
public nonisolated struct TerminalFontChoices {
    public let builtIn: [String]
    public let system: [String]

    public init(families: [String], builtInFamilies: Set<String>) {
        let available = Set(families).filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        builtIn = available.filter { builtInFamilies.contains($0) }
        system = available.filter { !builtInFamilies.contains($0) }
    }
}
