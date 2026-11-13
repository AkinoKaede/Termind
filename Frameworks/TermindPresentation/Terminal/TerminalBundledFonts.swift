// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// App-registered families available to both the picker and Ghostty.
public nonisolated enum TerminalBundledFonts {
    public static let families: Set<String> = ["JetBrains Mono", "SauceCodePro Nerd Font", "FiraCode Nerd Font"]

    public static func description(for family: String) -> LocalizedStringResource? {
        family == "SauceCodePro Nerd Font" ? AppStrings.Terminal.basedOnSourceCodePro : nil
    }
}
