import TermindDomain

public nonisolated protocol MetricsSampling: Sendable {
    func connect(_ configuration: SSHConnectionConfiguration) async throws
    func connect(_ request: SSHConnectionRequest) async throws
    func sample() async throws -> MetricsSample
    func filesystems() async throws -> [MetricsFilesystem]?
    func processes() async throws -> MetricsProcessSample?
    func gpu() async throws -> NvidiaSnapshot?
    func disconnect() async
}

nonisolated extension MetricsSampling {
    public func connect(_ request: SSHConnectionRequest) async throws {
        try await connect(request.configuration)
    }

    public func filesystems() async throws -> [MetricsFilesystem]? { nil }
    public func processes() async throws -> MetricsProcessSample? { nil }
}
