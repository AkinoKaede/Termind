import Foundation

/// Turns the chunks a running command emits into progress reports.
///
/// Locked rather than actor-isolated, because it is written from `libssh2`'s own
/// serial queue between two reads — see `SSHExecOutputHandler`, which may not
/// await. The callback fires outside the lock, so a slow reader cannot stall the
/// command it is reading.
///
/// Reports are throttled. A build printing a thousand lines a second would
/// otherwise raise a thousand events, each one a SwiftUI invalidation, to show
/// text nobody can read at that speed. The final result is not throttled and
/// arrives moments later either way, so the only thing a dropped report costs is
/// an intermediate frame.
nonisolated final class AgentCommandOutputStream: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOut = Data()
    private var standardError = Data()
    private var lastReportedAt: ContinuousClock.Instant?
    private let interval: Duration
    private let limit: Int
    private let report: @Sendable (String, String) -> Void

    init(
        interval: Duration = .milliseconds(150),
        limit: Int = 256 * 1_024,
        report: @escaping @Sendable (String, String) -> Void
    ) {
        self.interval = interval
        self.limit = limit
        self.report = report
    }

    /// The handler to hand to a session. Retains this stream for as long as the
    /// command runs, which is exactly its useful life.
    var handler: SSHExecOutputHandler {
        { [self] chunk, isStandardError in append(chunk, isStandardError: isStandardError) }
    }

    /// Everything captured so far, whether or not a report was due.
    var captured: (standardOut: String, standardError: String) {
        lock.withLock { (decoded(standardOut), decoded(standardError)) }
    }

    private func append(_ chunk: Data, isStandardError: Bool) {
        let due: (String, String)? = lock.withLock {
            if isStandardError {
                Self.appendCapped(chunk, to: &standardError, limit: limit)
            } else {
                Self.appendCapped(chunk, to: &standardOut, limit: limit)
            }
            let now = ContinuousClock.now
            if let lastReportedAt, now - lastReportedAt < interval { return nil }
            lastReportedAt = now
            return (decoded(standardOut), decoded(standardError))
        }
        guard let due else { return }
        report(due.0, due.1)
    }

    /// A chunk boundary can fall inside a multi-byte character, which decodes as
    /// a replacement character and corrects itself on the next report. Only the
    /// live view ever sees it: the finished result is decoded once, whole, by
    /// the session.
    private func decoded(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// The same head-keeping rule the session's own capture uses, so the live
    /// view and the finished result are never showing different ends of the
    /// same output.
    private static func appendCapped(_ chunk: Data, to buffer: inout Data, limit: Int) {
        guard buffer.count < limit else { return }
        buffer.append(chunk.prefix(limit - buffer.count))
    }
}
