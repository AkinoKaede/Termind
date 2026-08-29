import Foundation

/// A persisted label color shared by hosts, keys, and identities.
/// Presentation details live in DesignSystem so the domain value remains
/// usable without SwiftUI.
nonisolated enum TagColor: String, CaseIterable, Codable, Sendable, Identifiable {
    case none, red, orange, yellow, green, teal, blue, purple, pink

    nonisolated var id: String { rawValue }
}
