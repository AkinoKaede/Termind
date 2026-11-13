// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Observation
import TermindPresentation

@MainActor @Observable
final class TerminalFontCatalog {
    static let shared = TerminalFontCatalog()
    private(set) var families: [String] = []
    var builtInFamilies: Set<String> { TerminalBundledFonts.families.intersection(families) }

    private init() { refresh() }

    func refresh() {
        families = Set(NSFontManager.shared.availableFontFamilies).filter { family in
            NSFontManager.shared.availableMembers(ofFontFamily: family)?.contains { member in
                guard let fontName = member.first as? String else { return false }
                return NSFont(name: fontName, size: 12) != nil
            } == true
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
