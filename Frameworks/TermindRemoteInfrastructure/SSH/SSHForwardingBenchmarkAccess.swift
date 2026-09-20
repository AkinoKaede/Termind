import TermindDomain

@_spi(PortForwardingBenchmark)
public nonisolated struct SSHForwardingBenchmarkStatistics: Sendable {
    public let pumpPasses: Int
    public let plaintextSocketWriteCalls: Int
    public let encryptedSocketWriteCalls: Int
    public let peakPlaintextQueueBytes: Int
    public let peakEncryptedQueueBytes: Int

    init(_ statistics: SSHForwardingStatistics) {
        pumpPasses = statistics.passes
        plaintextSocketWriteCalls = statistics.plaintextSocketWriteCalls
        encryptedSocketWriteCalls = statistics.encryptedSocketWriteCalls
        peakPlaintextQueueBytes = statistics.peakPlaintextQueueBytes
        peakEncryptedQueueBytes = statistics.peakEncryptedQueueBytes
    }
}

/// A narrow SPI for the standalone Release benchmark. Shipping apps use
/// `PortForwardingController` and never depend on the benchmark executable.
@_spi(PortForwardingBenchmark)
public nonisolated enum SSHForwardingBenchmarkAccess {
    public static func makeSession(
        maximumConnections: Int,
        failureHandler: @escaping SSHForwardingSession.FailureHandler
    ) -> any SSHForwardingSessionProtocol {
        let maximum = Host.normalizedPortForwardingMaxConnections(maximumConnections)
        if maximum > 1 {
            return SSHForwardingPoolSession(
                maximumConnections: maximum,
                connectionHandler: { _, _, _ in },
                failureHandler: failureHandler)
        }
        return SSHForwardingSession(
            connectionHandler: { _, _, _ in },
            failureHandler: failureHandler)
    }

    public static func statistics(
        for session: any SSHForwardingSessionProtocol
    ) async -> SSHForwardingBenchmarkStatistics? {
        guard let session = session as? SSHForwardingSession else { return nil }
        return await SSHForwardingBenchmarkStatistics(session.statistics())
    }
}
