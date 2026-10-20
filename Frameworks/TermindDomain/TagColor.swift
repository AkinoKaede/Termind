// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A persisted label color shared by hosts, keys, identities, and forwarding rules.
/// Presentation details live in TermindPresentation so the domain value remains
/// usable without SwiftUI.
public nonisolated enum TagColor: String, CaseIterable, Codable, Sendable, Identifiable {
    case none, red, orange, yellow, green, teal, blue, purple, pink

    public nonisolated var id: String { rawValue }
}
