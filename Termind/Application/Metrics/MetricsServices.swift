import Foundation

nonisolated protocol MetricsSampling: Sendable {
    func connect(_ configuration: SSHConnectionConfiguration) async throws
    func sample() async throws -> MetricsSample
    func filesystems() async throws -> [MetricsFilesystem]?
    func processes() async throws -> MetricsProcessSample?
    func gpu() async throws -> NvidiaSnapshot?
    func disconnect() async
}

@MainActor
protocol MetricsConfigurationStoring {
    func load() -> [MetricsSelection]
    func save(_ selections: [MetricsSelection])
}

nonisolated struct MetricsClock: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var sleep: @Sendable (TimeInterval) async throws -> Void = {
        try await Task.sleep(for: .seconds($0))
    }
}

nonisolated extension MetricsSampling {
    func filesystems() async throws -> [MetricsFilesystem]? { nil }
    func processes() async throws -> MetricsProcessSample? { nil }
}
