// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation

/// Localized activity vocabulary supplied by the host, independent of tool identity.
nonisolated public struct AgentToolPresentationVocabulary: Sendable {
    public var activity: @Sendable (AgentToolDescriptor.Presentation.ActivityKind, Locale) -> String = { kind, _ in
        kind.rawValue
    }
    public var countedActivity: @Sendable (AgentToolDescriptor.Presentation.ActivityKind, Int, Locale) -> String? = {
        _, _, _ in nil
    }
    public var count: @Sendable (Int, AgentToolDescriptor.Presentation.CountedUnit, Locale) -> String = { count, _, _ in
        String(count)
    }

    public init() {}
}
