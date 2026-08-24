import Foundation

/// A persisted host label. Presentation details live in DesignSystem so the
/// domain value remains usable without SwiftUI.
nonisolated enum HostColor: String, CaseIterable, Codable, Sendable, Identifiable {
    case none, red, orange, yellow, green, teal, blue, purple, pink

    nonisolated var id: String { rawValue }
}
