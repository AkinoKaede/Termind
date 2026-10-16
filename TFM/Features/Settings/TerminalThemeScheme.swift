import Foundation

nonisolated enum TerminalCustomConfigurationScheme: String, Identifiable, Hashable, Sendable {
    case light
    case dark

    var id: String { rawValue }
}
