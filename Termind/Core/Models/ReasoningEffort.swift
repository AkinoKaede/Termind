import Foundation

/// The stable reasoning scale exposed by Termind.
///
/// A model may support only a subset; `ModelCapabilityResolver` owns that
/// provider-specific capability and wire mapping.
nonisolated enum ReasoningEffort: String, Codable, Sendable, CaseIterable, Identifiable {
    case off, minimal, low, medium, high, xHigh, max

    nonisolated var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: String(localized: "Off")
        case .minimal: String(localized: "Minimal")
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .xHigh: String(localized: "XHigh")
        case .max: String(localized: "Max")
        }
    }
}
