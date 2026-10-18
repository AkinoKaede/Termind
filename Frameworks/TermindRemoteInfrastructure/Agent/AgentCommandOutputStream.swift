import AgentKit
import Foundation
import TermindApplication

/// The SSH pump only enqueues bytes; generic capture, quotas and whole-line
/// selection belong to AgentKit. Both channels share callback-arrival order.
nonisolated public final class AgentCommandOutputStream: @unchecked Sendable {
    private let lock = NSLock()
    private let accumulator: AgentOutputAccumulator
    private var lastReportedAt: ContinuousClock.Instant?
    private let interval: Duration
    private let report: @Sendable (String, String) -> Void

    public init(
        interval: Duration = .milliseconds(150),
        accumulator: AgentOutputAccumulator,
        report: @escaping @Sendable (String, String) -> Void
    ) {
        self.interval = interval
        self.accumulator = accumulator
        self.report = report
    }

    public var captureID: UUID { accumulator.id }

    public var handler: SSHExecOutputHandler {
        { [self] chunk, _ in append(chunk) }
    }

    public func snapshot(
        envelopeBytes: Int = 0, capturePath: (@Sendable () -> String)? = nil
    ) async -> AgentOutputAccumulator.Snapshot {
        await accumulator.snapshot(envelopeBytes: envelopeBytes, capturePath: capturePath)
    }

    private func append(_ chunk: Data) {
        accumulator.append(chunk)
        let due: (@Sendable (String, String) -> Void)? = lock.withLock {
            let now = ContinuousClock.now
            if let lastReportedAt, now - lastReportedAt < interval { return nil }
            lastReportedAt = now
            return report
        }
        if let due { due(accumulator.preview, "") }
    }
}
