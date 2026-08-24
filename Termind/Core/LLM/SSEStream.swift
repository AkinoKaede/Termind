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

/// Parses `text/event-stream`.
///
/// Written now for MCP, which uses SSE on both of its HTTP transports, but this
/// is the parser P3's token streaming needs as well — all three chat APIs stream
/// this way. One parser, several callers, and the framing bugs get found once.
///
/// Two entry points over one `Accumulator`, because SSE arrives in both shapes
/// and hand-rolling the second would be the duplicate this file exists to
/// prevent: a long-lived stream, and a single response that a Streamable HTTP
/// POST returned whole.
nonisolated enum SSEStream {
    /// Events from a connection that stays open, in order, until the stream
    /// ends or the task is cancelled.
    ///
    /// A transport error surfaces as a thrown error rather than a silent end, so
    /// a dropped connection is not mistaken for a server that finished talking.
    ///
    /// `URLSession.AsyncBytes.lines` does the hard part of the framing: it
    /// splits on CR, LF, and CRLF, all three of which the specification allows
    /// and different servers actually send.
    static func events(from bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<SSEEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var accumulator = Accumulator()
                    for try await line in bytes.lines {
                        if let event = accumulator.consume(line) { continuation.yield(event) }
                    }
                    // A stream that ends without a trailing blank line still
                    // meant to send its last event.
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
        guard let text = String(data: body, encoding: .utf8) else { return [] }

        var accumulator = Accumulator()
        var events: [SSEEvent] = []
        // `omittingEmptySubsequences: false` matters: a blank line is what
        // dispatches an event, so dropping them would merge every event in the
        // body into one.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let event = accumulator.consume(String(line)) { events.append(event) }
        }
        if let event = accumulator.flush() { events.append(event) }
        return events
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
