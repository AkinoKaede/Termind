import Foundation

public nonisolated enum MetricsReadError: LocalizedError {
    case unsupported, output
    public var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Metrics requires a Linux server with procfs.")
        case .output: String(localized: "The metrics response is incomplete or too large.")
        }
    }
}
