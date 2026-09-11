import Foundation
import TermindApplication
import TermindDomain

nonisolated struct MetricsClock: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var sleep: @Sendable (TimeInterval) async throws -> Void = {
        try await Task.sleep(for: .seconds($0))
    }
}

typealias MetricsSampling = TermindApplication.MetricsSampling
typealias MetricsConfigurationStoring = TermindApplication.MetricsConfigurationStoring
