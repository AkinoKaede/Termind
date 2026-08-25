import Foundation

/// One dispatched `text/event-stream` event.
nonisolated struct SSEEvent: Hashable, Sendable {
    /// The `event:` field, or `message` when the stream did not name one — the
    /// default the SSE specification gives.
    var event: String = "message"
    /// Every `data:` line of this event, joined with newlines.
    var data: String = ""
    /// The `id:` field, which Streamable HTTP uses as a resume cursor.
    var id: String?

    var isEmpty: Bool { data.isEmpty && id == nil }
}

nonisolated enum SSEStreamError: LocalizedError, Sendable {
    case lineTooLong

    var errorDescription: String? {
        switch self {
        case .lineTooLong:
            String(localized: "The event stream sent a line that exceeded Termind's size limit.")
        }
    }
}

/// Parses `text/event-stream`.
///
/// Written now for MCP, which uses SSE on both of its HTTP transports, but this
/// is the parser P3's token streaming needs as well — all three chat APIs stream
/// this way. One parser, several callers, and the framing bugs get found once.
///
/// Two entry points over one `LineSplitter` and one `Accumulator`, because SSE
/// arrives in both shapes and hand-rolling either half twice is the duplicate
/// this file exists to prevent: a long-lived stream, and a single response that
/// a Streamable HTTP POST returned whole.
///
/// Both halves are ours on purpose. `AsyncLineSequence` — what `bytes.lines`
/// gives — *discards empty lines*, and a blank line is the only thing that
/// dispatches an SSE event, so framing on it silently folds an entire response
/// into one undelimited blob. Splitting bytes here is the whole reason this type
/// exists rather than being a call to `.lines`.
nonisolated enum SSEStream {
    /// Long enough for a gateway that puts a whole buffered response in one
    /// `data:` line, bounded so an endless line cannot exhaust memory.
    static let maximumLineBytes = 16 * 1_024 * 1_024

    /// Events from a connection that stays open, in order, until the stream
    /// ends or the task is cancelled.
    ///
    /// A transport error surfaces as a thrown error rather than a silent end, so
    /// a dropped connection is not mistaken for a server that finished talking.
    ///
    /// Generic over the byte source rather than taking `URLSession.AsyncBytes`
    /// directly, so the framing can be exercised without a socket.
    static func events<Bytes: AsyncSequence & Sendable>(
        from bytes: Bytes
    ) -> AsyncThrowingStream<SSEEvent, any Error> where Bytes.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var splitter = LineSplitter()
                    var accumulator = Accumulator()
                    for try await byte in bytes {
                        guard splitter.pendingCount <= maximumLineBytes else {
                            throw SSEStreamError.lineTooLong
                        }
                        guard let line = splitter.consume(byte) else { continue }
                        if let event = accumulator.consume(line) { continuation.yield(event) }
                    }
                    // A stream that ends without a trailing newline, or without
                    // a trailing blank line, still meant to send its last event.
                    if let line = splitter.flush(), let event = accumulator.consume(line) {
                        continuation.yield(event)
                    }
                    if let event = accumulator.flush() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Events from a complete, already-buffered body.
    static func events(in body: Data) -> [SSEEvent] {
        var splitter = LineSplitter()
        var accumulator = Accumulator()
        var events: [SSEEvent] = []
        for byte in body {
            guard let line = splitter.consume(byte) else { continue }
            if let event = accumulator.consume(line) { events.append(event) }
        }
        if let line = splitter.flush(), let event = accumulator.consume(line) { events.append(event) }
        if let event = accumulator.flush() { events.append(event) }
        return events
    }

    /// Turns bytes into lines, keeping the blank ones.
    ///
    /// The specification terminates a line with CRLF, LF, or a bare CR, and all
    /// three appear in the wild. A CR is dispatched immediately and the LF that
    /// may follow it is swallowed, so CRLF never produces a phantom blank line —
    /// which would dispatch an event halfway through one.
    nonisolated struct LineSplitter {
        private static let carriageReturn = UInt8(ascii: "\r")
        private static let lineFeed = UInt8(ascii: "\n")

        private var buffer: [UInt8] = []
        private var pendingLineFeed = false

        /// Bytes held for the line currently being read.
        var pendingCount: Int { buffer.count }

        mutating func consume(_ byte: UInt8) -> String? {
            if pendingLineFeed {
                pendingLineFeed = false
                if byte == Self.lineFeed { return nil }
            }
            switch byte {
            case Self.carriageReturn:
                pendingLineFeed = true
                return take()
            case Self.lineFeed:
                return take()
            default:
                buffer.append(byte)
                return nil
            }
        }

        /// The trailing line of a body that did not end with a terminator.
        mutating func flush() -> String? {
            buffer.isEmpty ? nil : take()
        }

        private mutating func take() -> String {
            defer { buffer.removeAll(keepingCapacity: true) }
            return String(decoding: buffer, as: UTF8.self)
        }
    }

    /// Turns lines into events. Returns one each time a blank line dispatches.
    nonisolated struct Accumulator {
        private var pending = SSEEvent()
        private var data: [String] = []

        mutating func consume(_ line: String) -> SSEEvent? {
            // A blank line dispatches whatever has accumulated. An event with
            // no data at all is a keep-alive artefact, and is dropped rather
            // than delivered.
            if line.isEmpty { return flush() }

            // `:` opens a comment. Servers send bare `:` lines as heartbeats to
            // stop proxies closing an idle stream.
            guard !line.hasPrefix(":") else { return nil }

            let (field, value) = Self.split(line)
            switch field {
            case "event": pending.event = value
            case "data": data.append(value)
            case "id": pending.id = value
            // A reconnection hint. Nothing here reconnects — MCP re-runs the
            // whole handshake — so it is read and ignored deliberately rather
            // than falling into the unknown-field case by accident.
            case "retry": break
            default: break
            }
            return nil
        }

        mutating func flush() -> SSEEvent? {
            pending.data = data.joined(separator: "\n")
            defer {
                pending = SSEEvent()
                data = []
            }
            return pending.isEmpty ? nil : pending
        }

        /// Splits `field: value`, dropping exactly one space after the colon.
        ///
        /// One, not all whitespace: the specification makes a single optional
        /// space part of the framing and everything after it payload. Trimming
        /// greedily corrupts any data line that legitimately starts with a
        /// space, which JSON does not but a streamed token very much does.
        private static func split(_ line: String) -> (field: String, value: String) {
            guard let colon = line.firstIndex(of: ":") else {
                // A line with no colon is a field name with an empty value.
                return (line, "")
            }
            let field = String(line[line.startIndex..<colon])
            var rest = line[line.index(after: colon)...]
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            return (field, String(rest))
        }
    }
}
