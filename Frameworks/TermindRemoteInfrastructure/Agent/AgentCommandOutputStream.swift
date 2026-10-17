import Foundation
import TermindApplication

/// A bounded UTF-8 tail with an in-band count of discarded Unicode scalars.
nonisolated struct AgentCommandOutputBuffer {
    private var data = Data()
    private var discardedCharacters = 0
    let limit: Int

    private var marker: String {
        discardedCharacters == 0 ? "" : "[\(discardedCharacters) chars were truncated]\n"
    }

    var text: String { marker + String(decoding: data, as: UTF8.self) }

    mutating func append(_ chunk: Data) {
        data.append(chunk)
        // The marker also counts toward the byte budget. Its digit count can grow
        // after a trim, so tighten again until both the text and marker fit.
        while data.count + marker.utf8.count > limit, !data.isEmpty {
            var count = min(data.count, max(1, data.count + marker.utf8.count - limit))
            while count < data.count, data[data.startIndex + count] & 0xC0 == 0x80 { count += 1 }
            discardedCharacters += String(decoding: data.prefix(count), as: UTF8.self).unicodeScalars.count
            data = Data(data.dropFirst(count))
        }
    }
}

/// Locked because the serial SSH pump cannot await an actor. Only progress is
/// throttled; snapshots always contain the latest bounded tail.
nonisolated public final class AgentCommandOutputStream: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOut: AgentCommandOutputBuffer
    private var standardError: AgentCommandOutputBuffer
    private var lastReportedAt: ContinuousClock.Instant?
    private let interval: Duration
    private var report: @Sendable (String, String) -> Void

    public init(
        interval: Duration = .milliseconds(150), limit: Int = 256 * 1_024,
        report: @escaping @Sendable (String, String) -> Void
    ) {
        self.interval = interval
        standardOut = AgentCommandOutputBuffer(limit: limit)
        standardError = AgentCommandOutputBuffer(limit: limit)
        self.report = report
    }

    public func redirect(to report: @escaping @Sendable (String, String) -> Void) {
        let output = lock.withLock {
            self.report = report
            lastReportedAt = nil
            return (standardOut.text, standardError.text)
        }
        report(output.0, output.1)
    }

    public var handler: SSHExecOutputHandler {
        { [self] chunk, isStandardError in append(chunk, isStandardError: isStandardError) }
    }

    public var captured: (standardOut: String, standardError: String) {
        lock.withLock { (standardOut.text, standardError.text) }
    }

    private func append(_ chunk: Data, isStandardError: Bool) {
        typealias Due = (String, String, @Sendable (String, String) -> Void)
        let due: Due? = lock.withLock {
            if isStandardError { standardError.append(chunk) } else { standardOut.append(chunk) }
            let now = ContinuousClock.now
            if let lastReportedAt, now - lastReportedAt < interval { return nil }
            lastReportedAt = now
            return (standardOut.text, standardError.text, report)
        }
        if let due { due.2(due.0, due.1) }
    }
}
