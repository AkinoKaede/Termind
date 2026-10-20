// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

public enum SnippetTimestamp {
    // Preserve the original iOS preference key so existing fallback dates survive upgrades.
    private static let fallbackKey = "mobile.snippets.baselineModifiedAtFallback.v1"

    public static func fallback(in defaults: UserDefaults?) -> Date {
        if let existing = defaults?.object(forKey: fallbackKey) as? Date { return existing }
        let date = Date()
        defaults?.set(date, forKey: fallbackKey)
        return date
    }

    public static func resolve(modifiedAt: Date?, fallback: Date) -> Date {
        guard let modifiedAt, modifiedAt > VaultVersion.baselineDate else { return fallback }
        return modifiedAt
    }
}
